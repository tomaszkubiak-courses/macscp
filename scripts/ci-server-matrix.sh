#!/bin/bash
set -euxo pipefail
PASSWORD=${MACSCP_TEST_PASSWORD:?}
KEYS=${KEYS:-/tmp/keys}

mkdir -p "$KEYS"
[ -f "$KEYS/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEYS/id_ed25519"
[ -f "$KEYS/id_encrypted" ] || ssh-keygen -q -t ed25519 -N 'test-pass' -f "$KEYS/id_encrypted"
cat "$KEYS/id_ed25519.pub" "$KEYS/id_encrypted.pub" > "$KEYS/authorized_keys"
for k in id_ed25519 id_encrypted; do ssh-keygen -e -f "$KEYS/$k.pub"; done > "$KEYS/authorized_keys.rfc4716"
chmod 644 "$KEYS"/*.pub "$KEYS"/authorized_keys*

USER_SETUP='
  install -d -m 700 -o macscp /home/macscp/.ssh
  cp /keys/authorized_keys /home/macscp/.ssh/authorized_keys
  chown macscp /home/macscp/.ssh/authorized_keys
  chmod 600 /home/macscp/.ssh/authorized_keys'

docker run -d --name busybox -p 2224:22 -v "$KEYS:/keys:ro" alpine:3.20 sh -c "
  apk add --no-cache dropbear dropbear-scp openssh-sftp-server >/dev/null
  adduser -D -s /bin/sh macscp && echo 'macscp:$PASSWORD' | chpasswd
  $USER_SETUP
  mkdir -p /etc/dropbear
  exec dropbear -F -E -R -p 22"

docker run -d --name openssh74 -p 2225:22 -v "$KEYS:/keys:ro" debian:stretch sh -c "
  echo 'deb http://archive.debian.org/debian stretch main' > /etc/apt/sources.list
  apt-get -o Acquire::Check-Valid-Until=false update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends openssh-server >/dev/null
  useradd -m -s /bin/bash macscp && echo 'macscp:$PASSWORD' | chpasswd
  $USER_SETUP
  mkdir -p /run/sshd
  exec /usr/sbin/sshd -D -e -o PasswordAuthentication=yes"

docker run -d --name proftpd -p 2226:22 -p 2127:2127 -p 2128:2128 -p 30000-30019:30000-30019 -v "$KEYS:/keys:ro" debian:bookworm sh -c "
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends proftpd-core proftpd-mod-crypto openssh-client ssl-cert >/dev/null
  useradd -m -s /bin/bash macscp && echo 'macscp:$PASSWORD' | chpasswd
  ssh-keygen -q -m PEM -t rsa -b 3072 -N '' -f /etc/proftpd/host_rsa
  ssh-keygen -q -m PEM -t ecdsa -N '' -f /etc/proftpd/host_ecdsa
  mkdir -p /etc/proftpd/authorized_keys && cp /keys/authorized_keys.rfc4716 /etc/proftpd/authorized_keys/macscp
  cat >> /etc/proftpd/proftpd.conf <<CONF
LoadModule mod_sftp.c
<IfModule mod_sftp.c>
  <VirtualHost 0.0.0.0>
    Port 22
    SFTPEngine on
    SFTPLog /dev/stderr
    SFTPHostKey /etc/proftpd/host_rsa
    SFTPHostKey /etc/proftpd/host_ecdsa
    SFTPAuthMethods publickey password
    SFTPAuthorizedUserKeys file:/etc/proftpd/authorized_keys/%u
    RequireValidShell off
    AllowOverwrite on
    DefaultRoot ~
  </VirtualHost>
</IfModule>
LoadModule mod_tls.c
<VirtualHost 0.0.0.0>
  Port 2127
  TLSEngine on
  TLSRequired off
  TLSRSACertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
  TLSRSACertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
  PassivePorts 30000 30009
  RequireValidShell off
  AllowOverwrite on
  DefaultRoot ~
</VirtualHost>
<VirtualHost 0.0.0.0>
  Port 2128
  TLSEngine on
  TLSOptions UseImplicitSSL
  TLSRSACertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
  TLSRSACertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
  PassivePorts 30010 30019
  RequireValidShell off
  AllowOverwrite on
  DefaultRoot ~
</VirtualHost>
CONF
  exec proftpd -n -q"

for p in 2224 2225 2226 2127 2128; do
  for _ in $(seq 120); do (echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null && break; sleep 1; done
done
sleep 3
docker ps
