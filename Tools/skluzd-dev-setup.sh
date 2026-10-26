#!/bin/sh
#
# skluzd-dev-setup.sh — prepare one System-mode test tunnel for skluzd, until
# the app can do it over XPC (PLAN_SKLUZD.md phases 4 to 6).
#
# Local only: generates a dedicated key, trusts the host key the calling user
# already trusts, and REPLACES the daemon's tunnels.json with this tunnel.
# The server is never touched: the restricted authorized_keys line to add
# there is printed at the end.
#
# Usage (skluzd must have run once to create its directory):
#   sudo Tools/skluzd-dev-setup.sh <name> <user@host> <ssh-port> <local-port> <remote-host> <remote-port>
#   sudo Tools/skluzd-dev-setup.sh vllm sb@dgx.haruni.net 2022 18000 localhost 8000

set -eu

[ "$(id -u)" = 0 ] || { echo "error: run with sudo" >&2; exit 1; }
[ $# -eq 6 ] || { sed -n '12,14p' "$0" >&2; exit 64; }

NAME=$1; DEST=$2; SSH_PORT=$3; LOCAL_PORT=$4; REMOTE_HOST=$5; REMOTE_PORT=$6
SSH_USER=${DEST%@*}; HOST=${DEST#*@}
[ "$SSH_USER" != "$DEST" ] || { echo "error: expected user@host, got $DEST" >&2; exit 64; }

BASE="/Library/Application Support/Skluz"
[ -d "$BASE/keys" ] || { echo "error: run skluzd once first, to create $BASE" >&2; exit 1; }
KEY="$BASE/keys/$NAME"

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "skluzd@$(hostname -s)" -f "$KEY"
fi
chown root:wheel "$KEY" "$KEY.pub"
chmod 600 "$KEY"
chmod 644 "$KEY.pub"

# Reuse the host key the invoking user already trusts, rather than accepting
# whatever ssh-keyscan returns.
HOST_ID=$HOST
[ "$SSH_PORT" = 22 ] || HOST_ID="[$HOST]:$SSH_PORT"
USER_HOME=$(dscl . -read "/Users/${SUDO_USER:?run through sudo}" NFSHomeDirectory | awk '{print $2}')
if ! ssh-keygen -F "$HOST_ID" -f "$USER_HOME/.ssh/known_hosts" | grep -v '^#' >> "$BASE/known_hosts"; then
  echo "error: $HOST_ID is not in $USER_HOME/.ssh/known_hosts — connect once with ssh first" >&2
  exit 1
fi

cat > "$BASE/tunnels.json" <<EOF
{
  "tunnels" : [
    {
      "autoRestart" : false,
      "autoStart" : false,
      "enabled" : true,
      "exposesOnNetwork" : false,
      "extraArgs" : [ ],
      "host" : "$HOST",
      "id" : "$(uuidgen)",
      "keyRef" : { "managed" : "$NAME" },
      "localPort" : $LOCAL_PORT,
      "mode" : "system",
      "name" : "$NAME",
      "port" : $SSH_PORT,
      "remoteHost" : "$REMOTE_HOST",
      "remotePort" : $REMOTE_PORT,
      "type" : "localForward",
      "user" : "$SSH_USER"
    }
  ],
  "version" : 2
}
EOF
chown root:wheel "$BASE/tunnels.json" "$BASE/known_hosts"
chmod 600 "$BASE/tunnels.json"
chmod 644 "$BASE/known_hosts"

echo "Ready. Add this line to ~$SSH_USER/.ssh/authorized_keys on $HOST:"
echo
echo "restrict,port-forwarding,permitopen=\"$REMOTE_HOST:$REMOTE_PORT\",command=\"/bin/false\" $(cat "$KEY.pub")"
