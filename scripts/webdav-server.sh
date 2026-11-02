#!/bin/bash
set -euo pipefail
WSGIDAV=$1 DIR=$2 USER_NAME=$3 PASSWORD=$4 CERT=$5 KEY=$6 PORT=$7 TLS_PORT=$8
mkdir -p "$DIR/root"
for spec in "$PORT:dav" "$TLS_PORT:dav-tls"; do
  port=${spec%%:*} name=${spec#*:}
  {
    echo "host: 127.0.0.1"
    echo "port: $port"
    echo "provider_mapping:"
    echo "  \"/\": \"$DIR/root\""
    echo "http_authenticator:"
    echo "  accept_basic: true"
    echo "  accept_digest: true"
    echo "  default_to_digest: false"
    echo "simple_dc:"
    echo "  user_mapping:"
    echo "    \"*\":"
    echo "      \"$USER_NAME\":"
    echo "        password: \"$PASSWORD\""
    if [ "$name" = dav-tls ]; then
      echo "ssl_certificate: \"$CERT\""
      echo "ssl_private_key: \"$KEY\""
    fi
    echo "verbose: 1"
  } > "$DIR/$name.yaml"
  "$WSGIDAV" --config "$DIR/$name.yaml" >"$DIR/$name.log" 2>&1 &
  echo $! > "$DIR/$name.pid"
done
