#!/usr/bin/env bash
# Shows the pairing address as a QR code, for the app to scan.
#
#   ./pair-qr.sh                 # in the terminal
#   ./pair-qr.sh -p              # also writes a PNG and opens it
#
# The address is rebuilt from the files that already hold the secrets
# (frpc.toml for the tunnel's basic auth, .env for the token), so there is
# never a second copy of them to keep in sync — or to leak.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
png=0
[ "${1:-}" = "-p" ] && png=1

command -v qrencode >/dev/null || {
  echo "qrencode manquant : sudo pacman -S qrencode" >&2; exit 1; }

toml="$here/frpc.toml"
env_file="$here/.env"
[ -r "$toml" ] || { echo "frpc.toml introuvable — voir SYNC.md" >&2; exit 1; }

host=$(grep -oP 'customDomains\s*=\s*\["\K[^"]+' "$toml")
user=$(grep -oP 'httpUser\s*=\s*"\K[^"]+' "$toml")
pass=$(grep -oP 'httpPassword\s*=\s*"\K[^"]+' "$toml")
token=""
[ -r "$env_file" ] && token=$(grep -oP '^DIKTAFON_TOKEN=\K.*' "$env_file" || true)

url="https://${user}:${pass}@${host}"
[ -n "$token" ] && url="${url}#${token}"

echo
echo "  Diktafon — appairage du téléphone"
echo "  ${host}${token:+  (jeton actif)}"
echo
qrencode -t UTF8 -m 2 "$url"
echo
echo "  Dans l'app : Réglages → Envoi vers le laptop → Adresse du laptop → SCANNER"
echo

if [ "$png" = 1 ]; then
  out="${TMPDIR:-/tmp}/diktafon-pairing.png"
  qrencode -o "$out" -s 8 -m 2 "$url"
  echo "  PNG : $out"
  command -v xdg-open >/dev/null && xdg-open "$out" >/dev/null 2>&1 || true
fi
