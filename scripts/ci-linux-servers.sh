#!/bin/bash
set -euxo pipefail
PASSWORD=${MACSCP_TEST_PASSWORD:?}

id macscp >/dev/null 2>&1 || useradd -m -s /bin/bash macscp
echo "macscp:$PASSWORD" | chpasswd

mkdir -p /keys
[ -f /keys/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /keys/id_ed25519
[ -f /keys/id_encrypted ] || ssh-keygen -q -t ed25519 -N 'test-pass' -f /keys/id_encrypted
install -d -m 700 -o macscp -g macscp /home/macscp/.ssh
cat /keys/id_ed25519.pub /keys/id_encrypted.pub "$(dirname "$0")/../Tests/RemoteCoreTests/Fixtures/rsa-v2-enc.pub" > /home/macscp/.ssh/authorized_keys
chown macscp:macscp /home/macscp/.ssh/authorized_keys
chmod 600 /home/macscp/.ssh/authorized_keys

sed -i 's/^session\s*required\s*pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd
mkdir -p /run/sshd
ssh-keygen -A
/usr/sbin/sshd -p 2222 -E /tmp/sshd.log -o UsePAM=yes -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes

mkdir -p /usr/libexec
ln -sf /usr/lib/openssh/sftp-server /usr/libexec/sftp-server
ln -sf /usr/lib/openssh/sftp-server /usr/lib/sftp-server
mkdir -p /etc/dropbear
dropbear -F -E -R -p 2223 >/tmp/dropbear.log 2>&1 &

mkdir -p /tmp/ftp-root /tmp/ftp-cert
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=localhost \
  -keyout /tmp/ftp-cert/key.pem -out /tmp/ftp-cert/cert.pem 2>/dev/null
python3 "$(dirname "$0")/ftp-server.py" 2121 /tmp/ftp-root macscp macscp-ftp /tmp/ftp-cert/cert.pem /tmp/ftp-cert/key.pem \
  >/tmp/ftpd.log 2>&1 &

VGW=v1.10.0
curl -fsSL "https://github.com/versity/versitygw/releases/download/$VGW/versitygw_${VGW}_Linux_x86_64.tar.gz" -o /tmp/vgw.tgz
echo "8f9869752939d4dc9cfe1bddb935a02cc6610e95319a3a9fc2947d2a6ebd2c91  /tmp/vgw.tgz" | sha256sum -c -
tar xzf /tmp/vgw.tgz -C /tmp && install /tmp/versitygw_${VGW}_Linux_x86_64/versitygw /usr/local/bin/
mkdir -p /tmp/s3-root/macscp
versitygw --access macscp --secret macscp-s3 --port 127.0.0.1:9000 posix /tmp/s3-root >/tmp/s3.log 2>&1 &
versitygw --access macscp --secret macscp-s3 --port 127.0.0.1:9001 --cert /tmp/ftp-cert/cert.pem --key /tmp/ftp-cert/key.pem \
  posix /tmp/s3-root >/tmp/s3-tls.log 2>&1 &

python3 -m pip install -q --break-system-packages wsgidav cheroot
"$(dirname "$0")/webdav-server.sh" "$(command -v wsgidav)" /tmp/webdav macscp macscp-dav /tmp/ftp-cert/cert.pem /tmp/ftp-cert/key.pem 8080 8443

ssh -N -D 127.0.0.1:1080 -p 2222 -i /keys/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR macscp@127.0.0.1 &
python3 "$(dirname "$0")/connect-proxy.py" 3128 >/tmp/http-proxy.log 2>&1 &

for p in 2222 2223 2121 9000 9001 8080 8443 1080 3128; do
  for _ in $(seq 50); do nc -z 127.0.0.1 $p && break; sleep 0.1; done
done
