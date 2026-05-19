"use strict";

const AWG_I1_SNI_CANDIDATES = [
  "mail.ru",
  "vk.com",
  "ozon.ru",
  "wildberries.ru",
  "cdn.jsdelivr.net",
  "cloudflare.com"
];

function pickAwgI1Sni() {
  return AWG_I1_SNI_CANDIDATES[
    Math.floor(Math.random() * AWG_I1_SNI_CANDIDATES.length)
  ];
}

function quicU8a(value) {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}

function quicStr8(data) {
  data = quicU8a(data);
  const out = new Uint8Array(data.byteLength + 1);
  out[0] = data.byteLength;
  out.set(data, 1);
  return out;
}

function quicStr16(data) {
  data = quicU8a(data);
  const out = new Uint8Array(data.byteLength + 2);
  new DataView(out.buffer).setUint16(0, data.byteLength, false);
  out.set(data, 2);
  return out;
}

function quicVarint(value) {
  if (value < 0x40) return new Uint8Array([value]);
  if (value < 0x4000) return new Uint8Array([0x40 | (value >> 8), value & 0xff]);
  if (value < 0x40000000) {
    return new Uint8Array([0x80 | (value >>> 24), (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]);
  }
  const out = new Uint8Array(8);
  const view = new DataView(out.buffer);
  const hi = Math.floor(value / 0x100000000);
  const lo = value >>> 0;
  view.setUint32(0, 0xc0000000 | hi, false);
  view.setUint32(4, lo, false);
  return out;
}

function quicVarintLength(value) {
  if (value < 0x40) return 1;
  if (value < 0x4000) return 2;
  if (value < 0x40000000) return 4;
  return 8;
}

function quicToHex(data) {
  return Array.from(quicU8a(data), b => b.toString(16).padStart(2, "0")).join("");
}

function quicConcatBuffers(buffers, prefixLength = 0) {
  const total = buffers.reduce((sum, item) => sum + quicU8a(item).byteLength, prefixLength);
  const out = new Uint8Array(total);
  let offset = prefixLength;
  for (const item of buffers) {
    const data = quicU8a(item);
    out.set(data, offset);
    offset += data.byteLength;
  }
  return out;
}

function quicCopyBuffer(data) {
  return new Uint8Array(quicU8a(data));
}

function quicXorBuffer(a, b) {
  a = quicU8a(a);
  b = quicU8a(b);
  const out = new Uint8Array(a.byteLength);
  for (let i = 0; i < a.byteLength; i += 1) out[i] = a[i] ^ b[i % b.byteLength];
  return out;
}

async function quicHmac(keyBytes, data) {
  const key = await window.crypto.subtle.importKey(
    "raw",
    quicU8a(keyBytes),
    {name: "HMAC", hash: "SHA-256"},
    false,
    ["sign"]
  );
  return new Uint8Array(await window.crypto.subtle.sign("HMAC", key, quicU8a(data)));
}

async function quicInitHmacKey(secret) {
  return window.crypto.subtle.importKey(
    "raw",
    quicU8a(secret),
    {name: "HMAC", hash: "SHA-256"},
    false,
    ["sign"]
  );
}

async function quicDeriveSecret(secret, label, length) {
  const enc = new TextEncoder();
  const info = quicConcatBuffers([
    new Uint8Array([0x00, length]),
    quicStr8(enc.encode(`tls13 ${label}`)),
    new Uint8Array([0x00])
  ]);
  const prk = await quicInitHmacKey(secret);
  return new Uint8Array(await window.crypto.subtle.sign("HMAC", prk, info)).slice(0, length);
}

async function quicEncryptPayload(keyBytes, ivBytes, packetNumber, aad, payload) {
  const nonce = quicCopyBuffer(ivBytes);
  const view = new DataView(nonce.buffer);
  view.setUint32(nonce.byteLength - 4, view.getUint32(nonce.byteLength - 4, false) ^ packetNumber, false);
  const key = await window.crypto.subtle.importKey("raw", quicU8a(keyBytes), {name: "AES-GCM"}, false, ["encrypt"]);
  return new Uint8Array(await window.crypto.subtle.encrypt({name: "AES-GCM", iv: nonce, additionalData: quicU8a(aad), tagLength: 128}, key, quicU8a(payload)));
}

async function quicDeriveHpMask(hpBytes, sample) {
  const key = await window.crypto.subtle.importKey("raw", quicU8a(hpBytes), {name: "AES-CTR"}, false, ["encrypt"]);
  const zeros = new Uint8Array(16);
  return new Uint8Array(await window.crypto.subtle.encrypt({name: "AES-CTR", counter: quicU8a(sample).slice(0, 16), length: 128}, key, zeros));
}

function quicMeasureLengths(dcid, scid, token, payloadLength, packetNumberLength) {
  const packetLength = packetNumberLength + payloadLength + 16;
  const headerLength = 1 + 4 + 1 + dcid.byteLength + 1 + scid.byteLength + quicVarintLength(token.byteLength) + token.byteLength + quicVarintLength(packetLength);
  return {headerLength, packetLength};
}

async function quicInitial(dcid, scid, token, pkn, payload, padTo = 0) {
  dcid = quicU8a(dcid);
  scid = quicU8a(scid);
  token = quicU8a(token);
  pkn = quicU8a(pkn);
  payload = quicU8a(payload);
  const paddedPayload = payload.byteLength < padTo
    ? quicConcatBuffers([payload, new Uint8Array(padTo - payload.byteLength)])
    : payload;
  const salt = new Uint8Array([0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a]);
  const initialSecret = await quicHmac(salt, dcid);
  const clientSecret = await quicDeriveSecret(initialSecret, "client in", 32);
  const key = await quicDeriveSecret(clientSecret, "quic key", 16);
  const iv = await quicDeriveSecret(clientSecret, "quic iv", 12);
  const hp = await quicDeriveSecret(clientSecret, "quic hp", 16);
  const lengths = quicMeasureLengths(dcid, scid, token, paddedPayload.byteLength, pkn.byteLength);
  const header = quicConcatBuffers([
    new Uint8Array([0xc0]),
    new Uint8Array([0x00, 0x00, 0x00, 0x01]),
    quicStr8(dcid),
    quicStr8(scid),
    quicVarint(token.byteLength),
    token,
    quicVarint(lengths.packetLength),
    pkn
  ]);
  const encrypted = await quicEncryptPayload(key, iv, pkn[0] || 0, header, paddedPayload);
  const packet = quicConcatBuffers([header, encrypted]);
  if (packet.byteLength >= header.byteLength + 16) {
    const mask = await quicDeriveHpMask(hp, packet.slice(header.byteLength, header.byteLength + 16));
    packet[0] ^= mask[0] & 0x0f;
    for (let i = 0; i < pkn.byteLength; i += 1) packet[header.byteLength - pkn.byteLength + i] ^= mask[i + 1];
  }
  return packet;
}

function quicCryptoFrame(offset, data) {
  return quicConcatBuffers([
    new Uint8Array([0x06]),
    quicVarint(offset),
    quicVarint(data.byteLength),
    data
  ]);
}

function quicTlsExt(type, data) {
  const out = new Uint8Array(data.byteLength + 4);
  const view = new DataView(out.buffer);
  view.setUint16(0, type, false);
  view.setUint16(2, data.byteLength, false);
  out.set(data, 4);
  return out;
}

function quicTlsExtSni(sni) {
  const host = new TextEncoder().encode(String(sni || "mail.ru").slice(0, 253));
  const name = quicConcatBuffers([new Uint8Array([0x00]), quicStr16(host)]);
  return quicTlsExt(0x0000, quicStr16(name));
}

function buildRealisticClientHello(sni) {
    const randomBytes = new Uint8Array(32);
    window.crypto.getRandomValues(randomBytes);

    // TLS_AES_128_GCM_SHA256, TLS_AES_256_GCM_SHA384, TLS_CHACHA20_POLY1305_SHA256
    const cipherSuites = new Uint8Array([
        0x00, 0x06,
        0x13, 0x01,
        0x13, 0x02,
        0x13, 0x03
    ]);

    // null compression
    const compressionMethods = new Uint8Array([0x01, 0x00]);

    const sniExt = quicTlsExtSni(sni);

    // supported_versions: TLS 1.3
    const suppVersions = quicTlsExt(0x002b, new Uint8Array([0x02, 0x03, 0x04]));

    // ALPN: h3
    const alpn = quicTlsExt(0x0010, new Uint8Array([0x00, 0x03, 0x02, 0x68, 0x33]));

    // supported_groups: X25519
    const suppGroups = quicTlsExt(0x000a, new Uint8Array([0x00, 0x02, 0x00, 0x1d]));

    // key_share: X25519 + random 32-byte key
    const keyShareData = new Uint8Array(36);
    keyShareData[0] = 0x00;
    keyShareData[1] = 0x1d;
    keyShareData[2] = 0x00;
    keyShareData[3] = 0x20;
    window.crypto.getRandomValues(new Uint8Array(keyShareData.buffer, 4, 32));
    const keyShare = quicTlsExt(0x0033, keyShareData);

    const extensions = quicConcatBuffers([
        sniExt,
        suppVersions,
        alpn,
        suppGroups,
        keyShare
    ]);

    const extLength = quicStr16(extensions);

    const payload = quicConcatBuffers([
        new Uint8Array([0x03, 0x03]),
        randomBytes,
        new Uint8Array([0x00]),
        cipherSuites,
        compressionMethods,
        extLength
    ], 4);

    const view = new DataView(payload);
    view.setUint32(0, payload.byteLength - 4, false);
    view.setUint8(0, 0x01);

    return payload;
}

function quicTlsClientHelloToFrames(clientHello, level = 0) {
  const cuts = [];
  const frames = [];
  let offset = 0;
  const minChunk = level > 0 ? 48 : clientHello.byteLength;
  while (offset < clientHello.byteLength) {
    const size = Math.min(clientHello.byteLength - offset, minChunk + Math.floor(Math.random() * 16));
    const frame = quicCryptoFrame(offset, clientHello.slice(offset, offset + size));
    cuts.push({offset, length: size});
    frames.push(frame);
    offset += size;
  }
  return [quicConcatBuffers(frames), cuts];
}

function quicFixCutSettings(cutSettings, packetLength, packetNumberLength, payloadLength) {
  for (const cut of cutSettings) {
    cut.packetLength = packetLength;
    cut.packetNumberLength = packetNumberLength;
    cut.payloadLength = payloadLength;
  }
  return cutSettings;
}

function quicToAWG(packet, cutSettings) {
  const parts = [`<b 0x${quicToHex(packet)}>`];
  for (const cut of cutSettings) {
    parts.push(`<r ${cut.offset} ${cut.length}>`);
  }
  return parts.join("");
}

async function generateAwgI1(sni, level = 0, padTo = 0) {
    const dcid = new Uint8Array(1);
    window.crypto.getRandomValues(dcid);

    const scid = new Uint8Array(0);
    const token = new Uint8Array(0);
    const pkn = new Uint8Array([0]);

    const clientHello = buildRealisticClientHello(sni);
    const [payload, cutSettings] = quicTlsClientHelloToFrames(clientHello, level);
    const packet = await quicInitial(dcid, scid, token, pkn, payload, padTo);
    quicFixCutSettings(cutSettings, packet.byteLength, pkn.byteLength, payload.byteLength);

    return quicToAWG(packet, cutSettings);
}

window.AWG_I1_SNI_CANDIDATES = AWG_I1_SNI_CANDIDATES;
window.pickAwgI1Sni = pickAwgI1Sni;
window.generateAwgI1 = generateAwgI1;
