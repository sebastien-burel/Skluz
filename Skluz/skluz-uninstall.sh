#!/bin/sh
#
# skluz-uninstall.sh — removes Skluz from this Mac: the system service, the
# app and the /usr/local/bin/skluz link. With --purge, also the system
# configuration (System tunnels, dedicated keys, known_hosts).
#
# Run as root, by the "Désinstaller Skluz" package or by
# `sudo skluz uninstall [--purge]`. Users' Session tunnels, in each
# ~/Library/Application Support/Skluz, are left untouched.

set -u

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" = 0 ] || { echo "skluz-uninstall: run as root" >&2; exit 1; }

APP="/Applications/Skluz.app"
BASE="/Library/Application Support/Skluz"
LINK="/usr/local/bin/skluz"
LABEL="net.haruni.skluzd"

say() { echo "skluz-uninstall: $*"; }

# 1. Stop the system service. On SIGTERM skluzd closes every ssh tunnel.
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
  say "stopping the system service"
  launchctl bootout "system/$LABEL" 2>/dev/null || true
fi

# A daemon that did not stop in time leaves its ssh behind: end those it
# registered, if they are still root's /usr/bin/ssh.
if [ -f "$BASE/runtime.json" ]; then
  for pid in $(plutil -extract pids json -o - "$BASE/runtime.json" 2>/dev/null | grep -oE ':[0-9]+' | tr -d :); do
    if [ "$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')" = root ] \
       && [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = /usr/bin/ssh ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
fi

# 2. Quit the menu bar app of every user, gracefully so that it closes its
# Session tunnels, then force whatever is left.
for pid in $(pgrep -x Skluz); do
  owner=$(ps -o uid= -p "$pid" | tr -d ' ')
  [ -n "$owner" ] && launchctl asuser "$owner" osascript -e 'quit app id "net.haruni.skluz"' >/dev/null 2>&1 || true
done
i=0
while pgrep -x Skluz >/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
pkill -x Skluz 2>/dev/null || true

# 3. The command-line link, only if it points to this app.
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$APP/Contents/Helpers/skluz" ]; then
  say "removing $LINK"
  rm -f "$LINK"
fi

# 4. The app and its installer receipt.
if [ -d "$APP" ]; then
  say "removing $APP"
  rm -rf "$APP"
fi
pkgutil --forget net.haruni.skluz.pkg >/dev/null 2>&1 || true

# 5. The system configuration, on request only: the dedicated keys are lost
# for good, their lines should also be removed from the servers.
if [ "$PURGE" = 1 ] && [ -d "$BASE" ]; then
  say "removing $BASE (System tunnels, dedicated keys, known_hosts)"
  rm -rf "$BASE"
elif [ -d "$BASE" ]; then
  say "keeping $BASE: a new install will find its System tunnels and keys"
fi

say "done"
