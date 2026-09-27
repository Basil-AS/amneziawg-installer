#!/usr/bin/env bash
# deploy-nextcloud-camouflage.sh
# Deploys authentic Nextcloud Hub login camouflage and secret admin URL routing for Nginx.
#
# Usage:
#   sudo ./scripts/deploy-nextcloud-camouflage.sh --domain <domain> [--secret <secret_prefix>] [--backend-port <port>]
#
set -euo pipefail

DOMAIN=""
SECRET_PREFIX=""
BACKEND_PORT="8080"
NEXTCLOUD_DIR="/var/www/nextcloud"
NGINX_SITES_AVAIL="/etc/nginx/sites-available"
NGINX_SITES_ENAB="/etc/nginx/sites-enabled"

log() { printf "\033[1;32m[+]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --secret) SECRET_PREFIX="$2"; shift 2 ;;
        --backend-port) BACKEND_PORT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: sudo $0 --domain <domain> [--secret <prefix>] [--backend-port <port>]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "This script must be run as root."
[[ -n "$DOMAIN" ]] || die "--domain is required (e.g. --domain s1.charles.men)"

if [[ -z "$SECRET_PREFIX" ]]; then
    SECRET_PREFIX="hub-mgr-$(od -An -N4 -tx1 /dev/urandom | tr -d ' ')"
fi
SECRET_PREFIX="${SECRET_PREFIX#/}"
SECRET_PREFIX="${SECRET_PREFIX%/}"
COOKIE_VAL="${SECRET_PREFIX#hub-mgr-}"
COOKIE_VAL="${COOKIE_VAL:-7f9a2b}"

command -v nginx >/dev/null 2>&1 || die "nginx is not installed"

log "Setting up Nextcloud camouflage assets in ${NEXTCLOUD_DIR}..."
mkdir -p "${NEXTCLOUD_DIR}/core/img/logo" "${NEXTCLOUD_DIR}/ocs/v1.php/cloud"

# 1. status.php
cat > "${NEXTCLOUD_DIR}/status.php" <<'EOF'
{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"29.0.5.1","versionstring":"29.0.5","edition":"","productname":"Nextcloud","extendedSupport":false}
EOF

# 2. OCS capabilities
cat > "${NEXTCLOUD_DIR}/ocs/v1.php/cloud/capabilities" <<'EOF'
<?xml version="1.0"?>
<ocs>
 <meta>
  <status>ok</status>
  <statuscode>100</statuscode>
  <message>OK</message>
 </meta>
 <data>
  <version>
   <major>29</major>
   <minor>0</minor>
   <micro>5</micro>
   <string>29.0.5</string>
   <edition></edition>
   <extendedSupport>false</extendedSupport>
  </version>
  <capabilities>
   <core>
    <pollinterval>60</pollinterval>
    <webdav-root>remote.php/webdav</webdav-root>
    <status>
     <installed>true</installed>
     <maintenance>false</maintenance>
     <needsDbUpgrade>false</needsDbUpgrade>
     <version>29.0.5.1</version>
     <versionstring>29.0.5</versionstring>
     <edition></edition>
     <productname>Nextcloud</productname>
     <extendedSupport>false</extendedSupport>
    </status>
   </core>
  </capabilities>
 </data>
</ocs>
EOF

# 3. Official Nextcloud Logo SVG
cat > "${NEXTCLOUD_DIR}/core/img/logo/logo.svg" <<'EOF'
<svg width="256" height="128" version="1.1" viewBox="0 0 256 128" xmlns="http://www.w3.org/2000/svg"><path d="m128 7c-25.871 0-47.817 17.485-54.713 41.209-5.9795-12.461-18.642-21.209-33.287-21.209-20.304 0-37 16.696-37 37s16.696 37 37 37c14.645 0 27.308-8.7481 33.287-21.209 6.8957 23.724 28.842 41.209 54.713 41.209s47.817-17.485 54.713-41.209c5.9795 12.461 18.642 21.209 33.287 21.209 20.304 0 37-16.696 37-37s-16.696-37-37-37c-14.645 0-27.308 8.7481-33.287 21.209-6.8957-23.724-28.842-41.209-54.713-41.209zm0 22c19.46 0 35 15.54 35 35s-15.54 35-35 35-35-15.54-35-35 15.54-35 35-35zm-88 20c8.4146 0 15 6.5854 15 15s-6.5854 15-15 15-15-6.5854-15-15 6.5854-15 15-15zm176 0c8.4146 0 15 6.5854 15 15s-6.5854 15-15 15-15-6.5854-15-15 6.5854-15 15-15z" color="#000000" fill="#fff" style="-inkscape-stroke:none"/></svg>
EOF

# 4. Fetch official background image if network is available
if curl -sI --max-time 4 https://cloud.nextcloud.com/apps/theming/img/background/jo-myoung-hee-fluid.webp | grep -q "200"; then
    curl -sL --max-time 10 https://cloud.nextcloud.com/apps/theming/img/background/jo-myoung-hee-fluid.webp -o "${NEXTCLOUD_DIR}/core/img/background.webp" || true
    curl -sL --max-time 10 https://cloud.nextcloud.com/core/img/favicon.ico -o "${NEXTCLOUD_DIR}/core/img/favicon.ico" || true
    cp -f "${NEXTCLOUD_DIR}/core/img/favicon.ico" "${NEXTCLOUD_DIR}/favicon.ico" 2>/dev/null || true
fi

# 5. Authentic Nextcloud Hub Login HTML
cat > "${NEXTCLOUD_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html class="ng-csp" data-placeholder-focus="false" lang="en">
<head>
  <meta charset="utf-8">
  <title>Nextcloud</title>
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0">
  <meta name="theme-color" content="#0082c9">
  <meta property="og:title" content="Nextcloud">
  <meta property="og:description" content="a safe home for all your data">
  <meta property="og:site_name" content="Nextcloud">
  <link rel="icon" type="image/x-icon" href="/core/img/favicon.ico">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #00679e url('/core/img/background.webp') no-repeat center center fixed;
      background-size: cover;
      color: #1e293b;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen-Sans, Ubuntu, Cantarell, "Helvetica Neue", Arial, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
      padding: 16px;
    }
    .wrapper {
      width: 100%;
      max-width: 360px;
      text-align: center;
      display: flex;
      flex-direction: column;
      align-items: center;
    }
    .logo-container {
      margin-bottom: 24px;
    }
    .logo-container svg {
      width: 175px;
      height: 90px;
      filter: drop-shadow(0 2px 16px rgba(0, 0, 0, 0.35));
    }
    .login-form {
      background: rgba(255, 255, 255, 0.94);
      backdrop-filter: blur(24px);
      -webkit-backdrop-filter: blur(24px);
      border: 1px solid rgba(255, 255, 255, 0.4);
      border-radius: 16px;
      padding: 32px 28px;
      box-shadow: 0 20px 48px rgba(0, 0, 0, 0.28);
      width: 100%;
      text-align: left;
    }
    .input-group {
      margin-bottom: 16px;
      position: relative;
    }
    .input-group label {
      position: absolute;
      width: 1px;
      height: 1px;
      padding: 0;
      margin: -1px;
      overflow: hidden;
      clip: rect(0, 0, 0, 0);
      border: 0;
    }
    .input-wrapper {
      position: relative;
      display: flex;
      align-items: center;
    }
    .input-icon {
      position: absolute;
      left: 14px;
      width: 18px;
      height: 18px;
      color: #94a3b8;
      pointer-events: none;
    }
    .input-group input {
      width: 100%;
      height: 44px;
      padding: 10px 42px 10px 42px;
      border: 1px solid #cbd5e1;
      border-radius: 10px;
      background: #ffffff;
      color: #0f172a;
      font-size: 14px;
      outline: none;
      transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
    }
    .input-group input:focus {
      border-color: #0082c9;
      box-shadow: 0 0 0 3px rgba(0, 130, 201, 0.2);
    }
    .toggle-pwd {
      position: absolute;
      right: 12px;
      background: none;
      border: none;
      color: #94a3b8;
      cursor: pointer;
      display: flex;
      align-items: center;
      padding: 4px;
    }
    .toggle-pwd:hover {
      color: #475569;
    }
    .btn-submit {
      width: 100%;
      height: 44px;
      border: none;
      border-radius: 10px;
      background: #0082c9;
      color: #fff;
      font-size: 15px;
      font-weight: 600;
      cursor: pointer;
      margin-top: 6px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      box-shadow: 0 4px 12px rgba(0, 130, 201, 0.3);
      transition: all 0.2s ease;
    }
    .btn-submit:hover {
      background: #0070ad;
      box-shadow: 0 6px 16px rgba(0, 130, 201, 0.4);
    }
    .btn-submit:active {
      transform: scale(0.99);
    }
    .btn-submit:disabled {
      background: #94a3b8;
      cursor: not-allowed;
      box-shadow: none;
    }
    .btn-device {
      width: 100%;
      height: 40px;
      border: 1px solid #cbd5e1;
      border-radius: 10px;
      background: transparent;
      color: #475569;
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      margin-top: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 6px;
      transition: background 0.15s;
    }
    .btn-device:hover {
      background: #f1f5f9;
      color: #1e293b;
    }
    .divider {
      display: flex;
      align-items: center;
      text-align: center;
      margin: 14px 0 6px 0;
      color: #94a3b8;
      font-size: 12px;
    }
    .divider::before, .divider::after {
      content: '';
      flex: 1;
      border-bottom: 1px solid #e2e8f0;
    }
    .divider span {
      padding: 0 10px;
    }
    .forgot-link {
      display: block;
      text-align: center;
      margin-top: 16px;
      color: #0082c9;
      font-size: 13px;
      font-weight: 500;
      text-decoration: none;
      transition: color 0.15s;
    }
    .forgot-link:hover {
      color: #005a8e;
      text-decoration: underline;
    }
    .footer {
      margin-top: 28px;
      font-size: 13px;
      color: rgba(255, 255, 255, 0.88);
      text-align: center;
      line-height: 1.6;
      text-shadow: 0 1px 4px rgba(0, 0, 0, 0.45);
    }
    .footer a {
      color: #fff;
      font-weight: 600;
      text-decoration: none;
    }
    .footer a:hover {
      text-decoration: underline;
    }
    .footer-sub {
      font-size: 11px;
      opacity: 0.85;
      display: block;
      margin-top: 2px;
    }
    .error-msg {
      display: none;
      background: #fef2f2;
      border-left: 4px solid #ef4444;
      color: #991b1b;
      padding: 12px 14px;
      border-radius: 6px;
      font-size: 13px;
      margin-bottom: 16px;
      line-height: 1.4;
    }
    .spinner {
      display: none;
      width: 18px;
      height: 18px;
      border: 2px solid rgba(255, 255, 255, 0.4);
      border-top-color: #fff;
      border-radius: 50%;
      animation: spin 0.8s linear infinite;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
  </style>
</head>
<body id="body-login">
  <div class="wrapper">
    <div class="logo-container">
      <svg width="256" height="128" viewBox="0 0 256 128" xmlns="http://www.w3.org/2000/svg">
        <path d="m128 7c-25.871 0-47.817 17.485-54.713 41.209-5.9795-12.461-18.642-21.209-33.287-21.209-20.304 0-37 16.696-37 37s16.696 37 37 37c14.645 0 27.308-8.7481 33.287-21.209 6.8957 23.724 28.842 41.209 54.713 41.209s47.817-17.485 54.713-41.209c5.9795 12.461 18.642 21.209 33.287 21.209 20.304 0 37-16.696 37-37s-16.696-37-37-37c-14.645 0-27.308 8.7481-33.287 21.209-6.8957-23.724-28.842-41.209-54.713-41.209zm0 22c19.46 0 35 15.54 35 35s-15.54 35-35 35-35-15.54-35-35 15.54-35 35-35zm-88 20c8.4146 0 15 6.5854 15 15s-6.5854 15-15 15-15-6.5854-15-15 6.5854-15 15-15zm176 0c8.4146 0 15 6.5854 15 15s-6.5854 15-15 15-15-6.5854-15-15 6.5854-15 15-15z" fill="#ffffff"/>
      </svg>
    </div>
    <div class="login-form">
      <div id="error" class="error-msg">
        <strong>Wrong username or password.</strong><br>
        Please check your credentials and try again.
      </div>
      <form id="loginForm" method="POST" action="/login">
        <div class="input-group">
          <label for="user">Username or email</label>
          <div class="input-wrapper">
            <svg class="input-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
              <circle cx="12" cy="7" r="4"></circle>
            </svg>
            <input type="text" id="user" name="user" placeholder="Username or email" autocomplete="username" required autofocus>
          </div>
        </div>
        <div class="input-group">
          <label for="password">Password</label>
          <div class="input-wrapper">
            <svg class="input-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
              <rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect>
              <path d="M7 11V7a5 5 0 0 1 10 0v4"></path>
            </svg>
            <input type="password" id="password" name="password" placeholder="Password" autocomplete="current-password" required>
            <button type="button" class="toggle-pwd" id="togglePwd" title="Show password">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
                <circle cx="12" cy="12" r="3"></circle>
              </svg>
            </button>
          </div>
        </div>
        <button type="submit" class="btn-submit" id="submitBtn">
          <span class="spinner" id="spinner"></span>
          <span id="btnText">Log in</span>
          <svg id="arrowIcon" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <line x1="5" y1="12" x2="19" y2="12"></line>
            <polyline points="12 5 19 12 12 19"></polyline>
          </svg>
        </button>
        <div class="divider"><span>or</span></div>
        <button type="button" class="btn-device" onclick="alert('Device authorization requires Nextcloud Hub connection.')">
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <rect x="5" y="2" width="14" height="20" rx="2" ry="2"></rect>
            <line x1="12" y1="18" x2="12.01" y2="18"></line>
          </svg>
          Log in with a device
        </button>
      </form>
      <a href="#" class="forgot-link" onclick="alert('Password reset link has been dispatched if account exists.')">Forgot password?</a>
    </div>
    <div class="footer">
      <a href="https://nextcloud.com" target="_blank" rel="noreferrer">Nextcloud</a> - a safe home for all your data
      <span class="footer-sub"><a href="https://nextcloud.com/privacy/" target="_blank" rel="noreferrer">Privacy policy</a></span>
    </div>
  </div>
  <script>
    document.getElementById("togglePwd").addEventListener("click", function() {
      var pwd = document.getElementById("password");
      if (pwd.type === "password") {
        pwd.type = "text";
      } else {
        pwd.type = "password";
      }
    });

    document.getElementById("loginForm").addEventListener("submit", function(e) {
      e.preventDefault();
      var btn = document.getElementById("submitBtn");
      var spinner = document.getElementById("spinner");
      var btnText = document.getElementById("btnText");
      var arrow = document.getElementById("arrowIcon");
      var err = document.getElementById("error");

      btn.disabled = true;
      spinner.style.display = "inline-block";
      arrow.style.display = "none";
      btnText.innerText = "Signing in...";
      err.style.display = "none";

      setTimeout(function() {
        btn.disabled = false;
        spinner.style.display = "none";
        arrow.style.display = "inline-block";
        btnText.innerText = "Log in";
        err.style.display = "block";
      }, 750);
    });
  </script>
</body>
</html>
EOF
cp -f "${NEXTCLOUD_DIR}/index.html" "${NEXTCLOUD_DIR}/login" 2>/dev/null || true

# 6. Nextcloud robots.txt
cat > "${NEXTCLOUD_DIR}/robots.txt" <<'EOF'
User-agent: *
Disallow: /
EOF

# Detect VPN tunnel IP
VPN_IP="$(ip -4 addr show awg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)"

log "Generating Nginx camouflage configuration for ${DOMAIN}..."

CONF_TARGET="${NGINX_SITES_AVAIL}/amneziawg-web"
cat > "${CONF_TARGET}" <<EOF
# Robust admin identification via Cookie or URL parameter
map "\$cookie___awg_adm:\$arg_adm" \$is_admin {
    default 0;
    "~${COOKIE_VAL}" 1;
}

server {
    server_name ${DOMAIN};
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Anti-DPI Nextcloud & HTTP/3 Camouflage Headers
    add_header Alt-Svc 'h3=":443"; ma=86400; persist=1' always;
    add_header X-Nextcloud-Version "29.0.5" always;
    add_header X-Powered-By "PHP/8.2.18" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Robots-Tag "none" always;
    add_header X-Download-Options "noopen" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;

    # Secret URL activation endpoint (matches with or without trailing slash)
    location ~* ^/${SECRET_PREFIX}/?$ {
        add_header Set-Cookie "__awg_adm=${COOKIE_VAL}; Path=/; HttpOnly; SameSite=Lax; Secure; Max-Age=2592000" always;
        return 302 /;
    }

    # Secret URL logout endpoint (matches with or without trailing slash)
    location ~* ^/hub-mgr-logout/?$ {
        add_header Set-Cookie "__awg_adm=; Path=/; HttpOnly; SameSite=Lax; Secure; Max-Age=0" always;
        return 302 /;
    }

    # Nextcloud simulated status.php
    location = /status.php {
        default_type application/json;
        return 200 '{"installed":true,"maintenance":false,"needsDbUpgrade":false,"version":"29.0.5.1","versionstring":"29.0.5","edition":"","productname":"Nextcloud","extendedSupport":false}';
    }

    # Nextcloud simulated capabilities
    location ^~ /ocs/ {
        default_type application/xml;
        alias ${NEXTCLOUD_DIR}/ocs/;
    }

    # Nextcloud WebDAV / CalDAV probes return 401 with Nextcloud realm
    location ~* ^/(remote\.php/(webdav|dav)|.well-known/(caldav|carddav)) {
        add_header WWW-Authenticate 'Basic realm="Nextcloud"' always;
        default_type application/json;
        return 401 '{"message":"Current user is not logged in"}';
    }

    # Nextcloud simulated login POST failure (returns 401)
    location ~* ^/(index\.php/)?login$ {
        default_type application/json;
        if (\$request_method = POST) {
            return 401 '{"message":"Wrong username or password."}';
        }
        root ${NEXTCLOUD_DIR};
        try_files /index.html =404;
    }

    # Nextcloud static assets (favicon, images, robots.txt)
    location ~* ^/(favicon\.ico|robots\.txt)$ {
        root ${NEXTCLOUD_DIR};
        try_files \$uri =404;
    }

    location ^~ /core/ {
        if (\$is_admin = 1) {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            break;
        }
        root ${NEXTCLOUD_DIR};
        try_files \$uri =404;
    }

    # Main routing: if admin, proxy to Web Panel; otherwise serve Nextcloud
    location / {
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        if (\$is_admin = 1) {
            proxy_pass http://127.0.0.1:${BACKEND_PORT};
            break;
        }

        root ${NEXTCLOUD_DIR};
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    # Proxied API calls for admin
    location /api/ {
        if (\$is_admin != 1) {
            return 404;
        }
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

if [[ -n "$VPN_IP" ]]; then
cat >> "${CONF_TARGET}" <<EOF

# Direct internal access from VPN tunnel
server {
    listen ${VPN_IP}:80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
EOF
fi

ln -sf "${CONF_TARGET}" "${NGINX_SITES_ENAB}/amneziawg-web"

if nginx -t; then
    systemctl reload nginx
    log "Nextcloud camouflage successfully deployed!"
    log "Public URL: https://${DOMAIN}/ (Camouflaged Nextcloud Hub)"
    log "Secret Admin URL: https://${DOMAIN}/${SECRET_PREFIX}/"
    log "Admin Cookie: __awg_adm=${COOKIE_VAL}"
    if [[ -n "$VPN_IP" ]]; then
        log "Direct VPN Admin URL: http://${VPN_IP}/"
    fi
else
    die "Nginx configuration test failed."
fi
