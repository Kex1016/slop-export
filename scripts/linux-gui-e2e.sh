#!/usr/bin/env bash
# Drives the real Linux app (GTK) through all five steps against the fixture servers, with a
# private X server, D-Bus session and keyring, and saves a screenshot of each step (D-016).
#
#   scripts/linux-gui-e2e.sh path/to/slop-export-gtk screenshot-dir
#
# Needs: xvfb xdotool imagemagick dbus gnome-keyring libsecret-tools dovecot-imapd python3 openssl.
# Starts the fixtures in /tmp/slopfx if they are not running. Uses iCloud fixture account 8.
set -euo pipefail

BIN=$(readlink -f "$1")
SHOTS=$(mkdir -p "$2" && cd "$2" && pwd)
ROOT=$(cd "$(dirname "$0")/.." && pwd)

if [ -z "${SLOP_E2E_INNER:-}" ]; then
  export SLOP_E2E_INNER=1
  exec dbus-run-session -- "$0" "$@"
fi

FX=/tmp/slopfx
[ -f "$FX/bridge.json" ] && [ -f "$FX/icloud.json" ] || python3 "$ROOT/Fixtures/slopfixture.py" up --dir "$FX" >/dev/null
fx() { python3 -c "import json,sys;print(json.load(open('$FX/$1.json'))['$2'])"; }

WORK=$(mktemp -d /tmp/slop-gui-XXXXXX)
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" NO_AT_BRIDGE=1
EXPORT="$WORK/My Export"
REPORT="$WORK/report.txt"
mkdir -p "$XDG_CONFIG_HOME/slop-export" "$EXPORT"
BRIDGE_USER=$(fx bridge user)
ICLOUD_USER=$(fx icloud user | sed 's/@/-8@/')
DER=$(openssl x509 -in "$(fx bridge cert)" -outform DER | base64 -w0)
cat > "$XDG_CONFIG_HOME/slop-export/settings.json" <<JSON
{"host": "127.0.0.1", "port": $(fx bridge port), "user": "$BRIDGE_USER",
 "certificateDER": "$DER", "certificateName": "cert.pem",
 "exportFolder": "$EXPORT", "icloudUser": "$ICLOUD_USER"}
JSON
export SLOP_ICLOUD_TEST_SERVER="127.0.0.1:$(fx icloud port)" SLOP_ICLOUD_TEST_CERT="$(fx icloud cert)"

printf 'e2e' | gnome-keyring-daemon --unlock --components=secrets >/dev/null 2>&1
Xvfb :97 -screen 0 1000x720x24 >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=:97
trap 'kill $XVFB 2>/dev/null || true' EXIT

fail() { echo "FAIL: $*" >&2; import -window root "$SHOTS/failure.png" || true; cat "$WORK/app.log" >&2 || true; exit 1; }
wait_for() {  # wait_for <seconds> <description> <test command...>
  local limit=$1 what=$2; shift 2
  for _ in $(seq $((limit * 4))); do "$@" && return 0; sleep 0.25; done
  fail "timed out waiting for $what"
}
shot() { sleep 1; import -window root "$SHOTS/$1.png"; }
key() { xdotool key --clearmodifiers "$@"; sleep 0.3; }
type_text() { xdotool type --delay 20 "$1"; sleep 0.3; }

# Xvfb takes a moment to accept connections; starting the app before that fails with
# "cannot open display".
wait_for 20 "the X server" sh -c 'xdotool getdisplaygeometry >/dev/null 2>&1'

"$BIN" >"$WORK/app.log" 2>&1 &
APP=$!
wait_for 20 "the window" sh -c 'xdotool search --name "^Slop Export$" >/dev/null 2>&1'
sleep 1

echo "Connect"
key alt+w; type_text "$(fx bridge password)"; key Return
shot 1-connect
wait_for 10 "the Bridge password in the keyring" \
  sh -c "secret-tool lookup service slop-export.bridge account '$BRIDGE_USER' | grep -qx '$(fx bridge password)'"

echo "Scan"
key alt+s
sleep 3
shot 2-scan

echo "Export"
key ctrl+3; key alt+s
wait_for 60 "the export manifest" test -f "$EXPORT/Proton Export/manifest.json"
shot 3-export
key alt+b
wait_for 30 "the Apple Mail mailboxes" test -d "$EXPORT/Apple Mail Import"
sleep 1

echo "Upload"
key ctrl+5; key alt+p; type_text "$(fx icloud password)"; key Return
key alt+c
sleep 3
shot 4-upload-check
key alt+u
shot 5-upload-confirm
key alt+u
uploaded() { [ "$(grep -c '"uploaded"' "$EXPORT/Proton Export/upload.jsonl" 2>/dev/null || echo 0)" -ge 13 ]; }
wait_for 60 "13 uploads in the journal" uploaded
shot 6-uploaded

echo "Verify"
key ctrl+4; key alt+v
sleep 4
shot 7-verify
key alt+t
sleep 1.5
key ctrl+a; type_text "$REPORT"; key Return
wait_for 10 "the saved report" test -s "$REPORT"
grep -q "Result: PASSED" "$REPORT" || { cat "$REPORT"; fail "verify did not pass"; }

echo "Checks"
! grep -q -e "$(fx bridge password)" -e "$(fx icloud password)" "$XDG_CONFIG_HOME/slop-export/settings.json" \
  || fail "a password ended up in settings.json"
grep -q "\"exportFolder\"" "$XDG_CONFIG_HOME/slop-export/settings.json" || fail "settings were not kept"
! grep -E "CRITICAL|Fatal error" "$WORK/app.log" || fail "GTK or Swift reported a critical error"

key ctrl+q
wait_for 10 "the app to quit" sh -c "! kill -0 $APP 2>/dev/null"
rm -rf "$WORK"
echo "PASSED: the GTK app connected, scanned, exported, built mailboxes, uploaded and verified."
