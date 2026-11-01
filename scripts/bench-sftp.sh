#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$ROOT/build/sshd
PORT=${PORT:-2222}
MIB=${1:-1024}
KEY=$DIR/id_ed25519
SRC=$DIR/payload.bin
CIPHER=${CIPHER:-aes128-gcm@openssh.com}

swift build -c release --package-path "$ROOT" >/dev/null
"$ROOT/scripts/test-servers.sh" start
trap '"$ROOT/scripts/test-servers.sh" stop' EXIT
[ "$(stat -f %z "$SRC" 2>/dev/null || echo 0)" = $((MIB << 20)) ] ||
  dd if=/dev/urandom of="$SRC" bs=1m count="$MIB" 2>/dev/null

OPTS=(-c "$CIPHER" -i "$KEY" -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
t0=$(perl -MTime::HiRes=time -e 'print time')
echo "get $SRC $DIR/out-sftp.bin" | sftp -q -b - "${OPTS[@]}" "$USER@127.0.0.1" >/dev/null
t1=$(perl -MTime::HiRes=time -e 'print time')
sftp_rate=$(perl -e "printf '%.1f', $MIB / ($t1 - $t0)")
echo "sftp:   $MIB MiB in $(perl -e "printf '%.2f', $t1 - $t0") s = $sftp_rate MiB/s"

out=$("$ROOT/.build/release/sftp-bench" 127.0.0.1 "$PORT" "$USER" "$KEY" "$SRC" "$DIR/out-libssh.bin" "${INFLIGHT:-16}" "$CIPHER")
echo "$out"
cmp -s "$SRC" "$DIR/out-libssh.bin" || { echo "FAIL: libssh download differs from source"; exit 1; }
rm -f "$DIR"/out-*.bin
lib_rate=$(echo "$out" | sed -E 's/.*= ([0-9.]+) MiB\/s.*/\1/')
perl -e "my \$r = $lib_rate / $sftp_rate; printf \"ratio: %.0f%% -> %s\n\", \$r*100, \$r >= 0.8 ? 'PASS' : 'FAIL'; exit(\$r < 0.8)"
