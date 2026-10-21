#!/bin/bash
# Starts the two sshd instances of a test server. What is secret comes from /run/test-env,
# mounted read-only by test-env.sh; without it the server still starts (a random host key,
# no way in), which is the safe default for an image that holds no credentials.
set -euo pipefail

mounted=/run/test-env

# A host key that survives "down" and "up": the app's known hosts stay valid, and a changed
# key during a test means what it should mean.
if [ -f "$mounted/hostkey/ssh_host_ed25519_key" ]; then
    install -m 600 "$mounted/hostkey/ssh_host_ed25519_key" /etc/ssh/ssh_host_ed25519_key
    install -m 644 "$mounted/hostkey/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub
else
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
fi

if [ -f "$mounted/tester_password" ]; then
    # chpasswd reads "user:password" from stdin: the password is never an argument.
    printf 'tester:%s\n' "$(cat "$mounted/tester_password")" | chpasswd
fi

install -d -m 700 -o tester -g tester /home/tester/.ssh
if [ -f "$mounted/authorized_keys" ]; then
    install -m 600 -o tester -g tester "$mounted/authorized_keys" /home/tester/.ssh/authorized_keys
fi

# Something to forward a port to: http://127.0.0.1:8080 answers "termi-forward-ok".
(cd /srv/www && python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &)

/usr/sbin/sshd -f /etc/ssh/sshd_kbd_config
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
