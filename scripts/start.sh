#!/bin/sh
# Bring the whole bridge up on a jailbroken (Dopamine, rootless) device.
#
#   ./scripts/start.sh 172.20.2.142
#
# What it does and why:
#   1. restart the root daemon (holds HID injection + the TCP API)
#   2. launch UIBridgeSvc.app -- it MUST be started by LaunchServices, because only
#      a GUI process inherits the session bootstrap where com.apple.iphone.axserver
#      lives. The device must be unlocked and awake for this to work.
#   3. verify that the app connected back to the daemon as an AX worker

set -eu

DEVICE="${1:-127.0.0.1}"
PORT="${2:-22}"
SSH="ssh -p $PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "==> restarting daemon"
$SSH root@"$DEVICE" '
  export PATH=/var/jb/usr/bin:/usr/bin:/bin
  launchctl bootout system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null || true
  launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.yg.uibridge.plist 2>/dev/null || true
  launchctl kickstart -k system/com.yg.uibridge 2>/dev/null || true
  sleep 2
  ps aux | grep -c "[u]ibridge 9700" || true
'

echo "==> launching AX worker app (device must be unlocked)"
$SSH root@"$DEVICE" 'su mobile -c "uiopen com.yg.uibridgesvc" 2>/dev/null || uiopen com.yg.uibridgesvc || true'

sleep 5

echo "==> verifying"
$SSH root@"$DEVICE" 'ps aux | grep "[U]IBridgeSvc.app" | head -1 || echo "app not running (is the device locked?)"'

printf '{"id":1,"cmd":"ping"}\n' | timeout 10 nc "$DEVICE" 9700 2>/dev/null || \
  python3 - "$DEVICE" <<'PY'
import socket, sys
host = sys.argv[1]
try:
    s = socket.create_connection((host, 9700), timeout=10)
    s.sendall(b'{"id":1,"cmd":"ping"}\n')
    print(s.recv(4096).decode().strip())
    s.close()
except Exception as exc:
    print("ping failed:", exc)
PY
