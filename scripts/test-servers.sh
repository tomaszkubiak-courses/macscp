#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/build/sshd
SSHD_PORT=${SSHD_PORT:-2222}
DROPBEAR_PORT=${DROPBEAR_PORT:-2223}

wait_port() {
  for _ in $(seq 50); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "server on port $1 did not start, see $DIR/*.log" >&2; return 1
}

stop() {
  for p in "$DIR"/sshd.pid "$DIR"/dropbear.pid; do
    [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null || true
    rm -f "$p"
  done
}

case "${1:-start}" in
start)
  stop
  mkdir -p "$DIR"
  [ -f "$DIR/host_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/host_ed25519"
  [ -f "$DIR/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/id_ed25519"
  [ -f "$DIR/id_encrypted" ] || ssh-keygen -q -t ed25519 -N 'test-pass' -f "$DIR/id_encrypted"
  cat "$DIR/id_ed25519.pub" "$DIR/id_encrypted.pub" > "$DIR/authorized_keys"
  chmod 600 "$DIR/authorized_keys"
  cat > "$DIR/sshd_config" <<CONF
Port $SSHD_PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
AuthorizedKeysFile $DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $DIR/sshd.pid
Subsystem sftp $(ls /usr/libexec/sftp-server /usr/lib/openssh/sftp-server 2>/dev/null | head -1)
CONF
  "$(command -v sshd || echo /usr/sbin/sshd)" -f "$DIR/sshd_config" -E "$DIR/sshd.log"
  wait_port "$SSHD_PORT"

  if command -v dropbear >/dev/null; then
    [ -f "$DIR/dropbear_host_ed25519" ] || dropbearkey -t ed25519 -f "$DIR/dropbear_host_ed25519" >/dev/null 2>&1
    dropbear -r "$DIR/dropbear_host_ed25519" -D "$DIR" -p "127.0.0.1:$DROPBEAR_PORT" -P "$DIR/dropbear.pid" -s -E 2>"$DIR/dropbear.log"
    wait_port "$DROPBEAR_PORT"
  fi ;;
stop) stop ;;
esac
