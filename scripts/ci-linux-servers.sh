#!/bin/bash
set -euxo pipefail
PASSWORD=${MACSCP_TEST_PASSWORD:?}

id macscp >/dev/null 2>&1 || useradd -m -s /bin/bash macscp
echo "macscp:$PASSWORD" | chpasswd

mkdir -p /keys
[ -f /keys/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /keys/id_ed25519
[ -f /keys/id_encrypted ] || ssh-keygen -q -t ed25519 -N 'test-pass' -f /keys/id_encrypted
install -d -m 700 -o macscp -g macscp /home/macscp/.ssh
cat /keys/id_ed25519.pub /keys/id_encrypted.pub > /home/macscp/.ssh/authorized_keys
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

for p in 2222 2223; do
  for _ in $(seq 50); do nc -z 127.0.0.1 $p && break; sleep 0.1; done
done
