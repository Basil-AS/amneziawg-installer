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

# 3. Logo SVG
cat > "${NEXTCLOUD_DIR}/core/img/logo/logo.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="128" height="128">
 <circle cx="512" cy="512" r="160" fill="#ffffff" />
 <circle cx="270" cy="512" r="100" fill="#ffffff" />
 <circle cx="754" cy="512" r="100" fill="#ffffff" />
</svg>
EOF

# 4. Login HTML
cat > "${NEXTCLOUD_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html class="ng-csp" data-placeholder-focus="false" lang="en">
<head>
  <meta charset="utf-8">
  <title>Nextcloud</title>
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0">
  <meta name="theme-color" content="#0082c9">
  <link rel="icon" href="/core/img/logo/logo.svg">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0082c9 linear-gradient(40deg, #0082c9 0%, #005a8e 100%);
      color: #fff;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen-Sans, Ubuntu, Cantarell, "Helvetica Neue", Arial, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      justify-content: center;
      align-items: center;
    }
    .wrapper { width: 100%; max-width: 360px; padding: 20px; text-align: center; }
    .logo-container { margin-bottom: 2rem; }
    .logo-container svg { width: 160px; height: auto; filter: drop-shadow(0 2px 8px rgba(0,0,0,0.2)); }
    .login-form {
      background: rgba(255, 255, 255, 0.15);
      backdrop-filter: blur(12px);
      -webkit-backdrop-filter: blur(12px);
      border: 1px solid rgba(255, 255, 255, 0.25);
      border-radius: 12px;
      padding: 28px 24px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
    }
    .input-group { margin-bottom: 14px; text-align: left; }
    .input-group label { display: block; font-size: 13px; margin-bottom: 6px; color: rgba(255, 255, 255, 0.9); font-weight: 500; }
    .input-group input {
      width: 100%; padding: 12px 14px; border: 1px solid rgba(255, 255, 255, 0.35); border-radius: 8px;
      background: rgba(255, 255, 255, 0.95); color: #222; font-size: 14px; outline: none; transition: all 0.2s;
    }
    .input-group input:focus { border-color: #fff; box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.4); background: #fff; }
    .btn-submit {
      width: 100%; padding: 13px; border: none; border-radius: 8px; background: #0082c9; color: #fff;
      font-size: 15px; font-weight: 600; cursor: pointer; margin-top: 10px; box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
    }
    .btn-submit:hover { background: #0070ad; }
    .forgot-link { display: inline-block; margin-top: 16px; color: rgba(255, 255, 255, 0.85); font-size: 13px; text-decoration: none; }
    .footer { margin-top: 2rem; font-size: 12px; color: rgba(255, 255, 255, 0.7); }
    .footer a { color: rgba(255, 255, 255, 0.9); text-decoration: none; }
    .error-msg { display: none; background: rgba(230, 50, 50, 0.85); color: #fff; padding: 10px; border-radius: 6px; font-size: 13px; margin-bottom: 14px; }
  </style>
</head>
<body id="body-login">
  <div class="wrapper">
    <div class="logo-container">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="128" height="128"><circle cx="512" cy="512" r="160" fill="#ffffff" /><circle cx="270" cy="512" r="100" fill="#ffffff" /><circle cx="754" cy="512" r="100" fill="#ffffff" /></svg>
    </div>
    <div class="login-form">
      <div id="error" class="error-msg">Wrong username or password.</div>
      <form id="loginForm" method="POST" action="/login">
        <div class="input-group">
          <label for="user">Username or email</label>
          <input type="text" id="user" name="user" autocomplete="username" required autofocus>
        </div>
        <div class="input-group">
          <label for="password">Password</label>
          <input type="password" id="password" name="password" autocomplete="current-password" required>
        </div>
        <button type="submit" class="btn-submit" id="submitBtn">Log in</button>
      </form>
      <a href="#" class="forgot-link">Forgot password?</a>
    </div>
    <div class="footer">
      <a href="https://nextcloud.com" target="_blank" rel="noreferrer">Nextcloud</a> - a safe home for all your data
    </div>
  </div>
  <script>
    document.getElementById("loginForm").addEventListener("submit", function(e) {
      e.preventDefault();
      var btn = document.getElementById("submitBtn");
      var err = document.getElementById("error");
      btn.innerText = "Logging in...";
      btn.disabled = true;
      err.style.display = "none";
      setTimeout(function() {
        btn.innerText = "Log in";
        btn.disabled = false;
        err.style.display = "block";
      }, 700);
    });
  </script>
</body>
</html>
EOF
cp "${NEXTCLOUD_DIR}/index.html" "${NEXTCLOUD_DIR}/login"

# Detect VPN tunnel IP
VPN_IP="$(ip -4 addr show awg0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)"

log "Generating Nginx camouflage configuration for ${DOMAIN}..."

CONF_TARGET="${NGINX_SITES_AVAIL}/amneziawg-web"
cat > "${CONF_TARGET}" <<EOF
map \$cookie___awg_adm \$is_admin {
    default 0;
    "${COOKIE_VAL}" 1;
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

    # Secret URL activation endpoint
    location = /${SECRET_PREFIX}/ {
        add_header Set-Cookie "__awg_adm=${COOKIE_VAL}; Path=/; HttpOnly; SameSite=Lax; Secure" always;
        return 302 /;
    }

    # Secret URL logout endpoint
    location = /hub-mgr-logout/ {
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

    # Nextcloud simulated login POST failure (returns 401)
    location ~* ^/(index\.php/)?login$ {
        default_type application/json;
        if (\$request_method = POST) {
            return 401 '{"message":"Wrong username or password."}';
        }
        root ${NEXTCLOUD_DIR};
        try_files /index.html =404;
    }

    # Nextcloud static assets
    location ^~ /core/ {
        root ${NEXTCLOUD_DIR};
        try_files \$uri =404;
    }

    # Main routing: if admin cookie is set, proxy to Web Panel; otherwise serve Nextcloud
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
