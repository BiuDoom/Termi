# The SSH server every container of the Termi test environment runs (see ../test-env.sh and
# docs/TESTING.md). Nothing secret is built in: the password of "tester", the keys it accepts
# and the server's host key are mounted read-only at /run/test-env when a container starts.
FROM ubuntu:24.04

# openssh-server is the point; the rest is what acceptance checks type into a terminal
# (full-screen programs, a pager) or need for port forwarding (python3 serves a page).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server vim htop tmux less procps iproute2 netcat-openbsd python3 locales \
 && mkdir -p /run/sshd /srv/www \
 && (locale-gen en_US.UTF-8 || true)

RUN useradd -m -s /bin/bash tester \
 && echo 'termi-forward-ok' > /srv/www/index.html

COPY sshd_config /etc/ssh/sshd_config
COPY sshd_kbd_config /etc/ssh/sshd_kbd_config
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 22: password and public key. 2224: keyboard-interactive only.
EXPOSE 22 2224
ENTRYPOINT ["/entrypoint.sh"]
