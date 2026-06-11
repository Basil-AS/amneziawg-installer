#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sha() {
    sha256sum "$1" | awk '{print $1}'
}

replace_sha() {
    local file="$1" key="$2" value="$3"
    python3 - "$file" "$key" "$value" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = re.escape(sys.argv[2])
value = sys.argv[3]
text = path.read_text(encoding="utf-8")
pattern = rf'(\["{key}"\]=")[0-9a-fA-F]{{64}}(")'
new, count = re.subn(pattern, rf"\g<1>{value}\2", text)
if count != 1:
    raise SystemExit(f"manifest key not found or duplicated: {sys.argv[2]} in {path}")
path.write_text(new, encoding="utf-8")
PY
}

replace_sha install_amneziawg.sh "awg_common.sh" "$(sha awg_common.sh)"
replace_sha install_amneziawg.sh "manage_amneziawg.sh" "$(sha manage_amneziawg.sh)"
replace_sha install_amneziawg_en.sh "awg_common_en.sh" "$(sha awg_common_en.sh)"
replace_sha install_amneziawg_en.sh "manage_amneziawg_en.sh" "$(sha manage_amneziawg_en.sh)"

for asset in \
    web/server.py \
    web/index.html \
    web/app.js \
    web/awg_i1.js \
    web/style.css \
    web/favicon.svg \
    web/vendor/tailwindcss.js \
    web/vendor/apexcharts.min.js \
    scripts/update_geoip_dbs.py
do
    digest="$(sha "$asset")"
    replace_sha install_amneziawg.sh "$asset" "$digest"
    replace_sha install_amneziawg_en.sh "$asset" "$digest"
done

echo "Installer SHA256 manifests updated."
