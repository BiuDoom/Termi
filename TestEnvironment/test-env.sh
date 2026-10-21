#!/bin/bash
# test-env.sh up | down | status — the SSH servers acceptance testing needs, rebuilt from this
# repository on any Mac with Docker (see docs/TESTING.md).
#
#   termi-test-a      127.0.0.1:2222  password and public key
#                      127.0.0.1:2224  keyboard-interactive only
#   termi-test-jump   127.0.0.1:2223  a jump host
#   termi-test-inner  (no port)       "inner", reachable only through the jump host
#
# Everything secret is generated on this machine into .test-env/ at the repository root
# (git-ignored, 0700, files 0600) and is never printed: this script prints paths.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$ROOT_DIR/.test-env"

IMAGE="termi-test-env-sshd:local"
NETWORK="termi-test-env"
# Marks the network as made by this script: "down" removes only a network that carries it.
NETWORK_LABEL="dev.termi.termi.test-env=1"
# On each container: the .test-env/ it was started with. Container names are the same for every
# checkout on this Mac, and a server started from another one has another password and other keys.
OWNER_LABEL="dev.termi.termi.test-env.dir"
SERVERS=(a jump inner)
TESTER="tester"
BIND="127.0.0.1"

die() { printf 'test-env: %s\n' "$*" >&2; exit 1; }

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed (Docker Desktop, OrbStack or colima)."
    docker info >/dev/null 2>&1 || die "the Docker daemon does not answer — start it first."
}

container_name() { printf 'termi-test-%s' "$1"; }

# "running", "exited", … or "absent". The name filter is anchored: "termi-test-a" must not
# match a container somebody called "termi-test-abc".
container_state() {
    local state
    state="$(docker ps -a --filter "name=^/$(container_name "$1")\$" --format '{{.State}}')"
    printf '%s' "${state:-absent}"
}

# The .test-env/ a container was started with; empty for one this script did not label.
container_owner() {
    docker inspect --format "{{index .Config.Labels \"$OWNER_LABEL\"}}" "$(container_name "$1")" 2>/dev/null || true
}

# The ports a server publishes on this Mac.
server_ports() {
    case "$1" in
        a)    printf '2222 2224' ;;
        jump) printf '2223' ;;
        *)    ;;
    esac
}

# Whether anything accepts connections there. In a subshell, so the descriptor closes with it.
port_in_use() { (exec 3<>"/dev/tcp/$BIND/$1") 2>/dev/null; }

network_exists() { docker network inspect "$NETWORK" >/dev/null 2>&1; }

network_is_ours() {
    [ "$(docker network inspect "$NETWORK" --format '{{index .Labels "dev.termi.termi.test-env"}}' 2>/dev/null)" = "1" ]
}

# Whether an SSH server answers there: the banner, not just an open port — Docker accepts
# connections on a published port before the server inside listens.
ssh_answers() {
    local port="$1" banner=""
    # A closed port is an answer ("no"), not something to print while waiting.
    { exec 3<>"/dev/tcp/$BIND/$port"; } 2>/dev/null || return 1
    IFS= read -r -t 2 banner <&3 || true
    exec 3<&- 3>&-
    [[ "$banner" == SSH-* ]]
}

inner_answers() {
    docker exec "$(container_name jump)" bash -c \
        'exec 3<>/dev/tcp/inner/22 && IFS= read -r -t 2 banner <&3 && [[ "$banner" == SSH-* ]]' >/dev/null 2>&1
}

random_secret() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# ---------------------------------------------------------------------------------------------
# What is secret, generated once. A second "up" keeps what exists, so the app's saved passwords,
# keys and known hosts stay valid across "down" and "up".
# ---------------------------------------------------------------------------------------------
generate_material() {
    case "$ENV_DIR" in
        *'"'*|*'\'*|*'&'*|*$'\n'*) die "the repository path contains a quote, a backslash, an ampersand or a line break; the generated files cannot name it." ;;
    esac
    mkdir -p "$ENV_DIR" "$ENV_DIR/profile"
    chmod 700 "$ENV_DIR" "$ENV_DIR/profile"

    [ -s "$ENV_DIR/tester_password" ] || random_secret > "$ENV_DIR/tester_password"
    [ -s "$ENV_DIR/key_passphrase" ] || random_secret > "$ENV_DIR/key_passphrase"

    # ssh-keygen asks this for the passphrase, so the passphrase is never a command argument.
    printf '#!/bin/sh\ncat "$TEST_ENV_ASKPASS_FILE"\n' > "$ENV_DIR/askpass.sh"
    chmod 700 "$ENV_DIR/askpass.sh"

    local key
    for key in id_plain id_passphrase id_agent; do
        [ -f "$ENV_DIR/$key" ] && continue
        ssh-keygen -q -t ed25519 -N '' -C "termi-test-env ${key#id_}" -f "$ENV_DIR/$key"
        if [ "$key" = id_passphrase ]; then
            TEST_ENV_ASKPASS_FILE="$ENV_DIR/key_passphrase" SSH_ASKPASS="$ENV_DIR/askpass.sh" \
                SSH_ASKPASS_REQUIRE=force ssh-keygen -q -p -f "$ENV_DIR/$key" </dev/null >/dev/null
        fi
    done
    cat "$ENV_DIR/id_plain.pub" "$ENV_DIR/id_passphrase.pub" "$ENV_DIR/id_agent.pub" > "$ENV_DIR/authorized_keys"

    local server
    for server in "${SERVERS[@]}"; do
        mkdir -p "$ENV_DIR/hostkeys/$server"
        [ -f "$ENV_DIR/hostkeys/$server/ssh_host_ed25519_key" ] \
            || ssh-keygen -q -t ed25519 -N '' -C "termi-test-$server" -f "$ENV_DIR/hostkeys/$server/ssh_host_ed25519_key"
    done

    # For checking the servers with plain ssh without touching ~/.ssh: its own known hosts
    # (the generated host keys) and its own configuration.
    {
        printf '[%s]:2222 %s\n' "$BIND" "$(cut -d' ' -f1,2 "$ENV_DIR/hostkeys/a/ssh_host_ed25519_key.pub")"
        printf '[%s]:2224 %s\n' "$BIND" "$(cut -d' ' -f1,2 "$ENV_DIR/hostkeys/a/ssh_host_ed25519_key.pub")"
        printf '[%s]:2223 %s\n' "$BIND" "$(cut -d' ' -f1,2 "$ENV_DIR/hostkeys/jump/ssh_host_ed25519_key.pub")"
        printf 'inner %s\n' "$(cut -d' ' -f1,2 "$ENV_DIR/hostkeys/inner/ssh_host_ed25519_key.pub")"
    } > "$ENV_DIR/known_hosts"
    cat > "$ENV_DIR/ssh_config" <<EOF
# Generated by TestEnvironment/test-env.sh — ssh -F "$ENV_DIR/ssh_config" test-a
Host test-a
    HostName $BIND
    Port 2222
Host test-kbd
    HostName $BIND
    Port 2224
    PubkeyAuthentication no
    PreferredAuthentications keyboard-interactive
Host jump
    HostName $BIND
    Port 2223
Host inner
    HostName inner
    ProxyJump jump
Host *
    User $TESTER
    IdentityFile "$ENV_DIR/id_plain"
    IdentitiesOnly yes
    UserKnownHostsFile "$ENV_DIR/known_hosts"
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
EOF

    # The hosts the app is seeded with (-debugSeedHosts), naming the files generated above.
    local template
    template="$(cat "$SCRIPT_DIR/seed-hosts.template.json")"
    printf '%s\n' "${template//@TEST_ENV@/$ENV_DIR}" > "$ENV_DIR/seed-hosts.json"

    chmod 600 "$ENV_DIR/tester_password" "$ENV_DIR/key_passphrase" "$ENV_DIR/authorized_keys" \
        "$ENV_DIR/known_hosts" "$ENV_DIR/ssh_config" "$ENV_DIR/seed-hosts.json" \
        "$ENV_DIR/id_plain" "$ENV_DIR/id_passphrase" "$ENV_DIR/id_agent"
}

start_server() {
    local server="$1" name state
    name="$(container_name "$server")"
    state="$(container_state "$server")"
    case "$state" in
        running)
            printf '  %-18s already running\n' "$name"
            return ;;
        absent) ;;
        *)
            # Stopped (a restart of Docker, a reboot): the same container, started again.
            RESTARTED+=("$name")
            docker start "$name" >/dev/null
            printf '  %-18s started again (was %s)\n' "$name" "$state"
            return ;;
    esac

    # Read-only mounts of exactly what a server needs. The client's private keys and the
    # passphrase stay on this side.
    local arguments=(
        --name "$name" --hostname "test-$server" --network "$NETWORK"
        --label "$NETWORK_LABEL" --label "$OWNER_LABEL=$ENV_DIR"
        --volume "$ENV_DIR/tester_password:/run/test-env/tester_password:ro"
        --volume "$ENV_DIR/authorized_keys:/run/test-env/authorized_keys:ro"
        --volume "$ENV_DIR/hostkeys/$server:/run/test-env/hostkey:ro"
    )
    case "$server" in
        a)     arguments+=(--publish "$BIND:2222:22" --publish "$BIND:2224:2224") ;;
        jump)  arguments+=(--publish "$BIND:2223:22") ;;
        # No published port: the only way in is through the jump host, by this name.
        inner) arguments+=(--network-alias inner) ;;
    esac
    # Created, recorded by its id, then started. By id and not by name: two "up" runs can both
    # find the name free; the one that loses the race gets no container ("docker create" refuses
    # the name) and must not take back the winner's. Recorded before the start: a refused start
    # (a port taken meanwhile) leaves a created container, and that one is ours to remove.
    local id
    id="$(docker create "${arguments[@]}" "$IMAGE")"
    CREATED+=("$id")
    CREATED_NAMES+=("$name")
    docker start "$id" >/dev/null
    printf '  %-18s started\n' "$name"
}

wait_for_servers() {
    local deadline=$((SECONDS + 30)) missing
    while :; do
        missing=""
        ssh_answers 2222 || missing="$missing $BIND:2222"
        ssh_answers 2224 || missing="$missing $BIND:2224"
        ssh_answers 2223 || missing="$missing $BIND:2223"
        inner_answers || missing="$missing inner:22"
        [ -z "$missing" ] && return 0
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 0.5
    done
    die "no SSH server answered at$missing within 30 seconds. If another program holds the port: lsof -nP -iTCP -sTCP:LISTEN"
}

# Before anything is started: what would make "up" stop half-way, or end with servers that do
# not match this checkout's password and keys.
preflight() {
    local server name state owner port
    for server in "${SERVERS[@]}"; do
        name="$(container_name "$server")"
        state="$(container_state "$server")"
        if [ "$state" != absent ]; then
            owner="$(container_owner "$server")"
            [ "$owner" = "$ENV_DIR" ] || die "$name exists and was started from another checkout (${owner:-unknown}): its password and keys are not the ones in $ENV_DIR. Run \"down\" first, then \"up\". Nothing was started."
        fi
        [ "$state" = running ] && continue
        for port in $(server_ports "$server"); do
            if port_in_use "$port"; then
                die "$BIND:$port is already in use by another program (lsof -nP -iTCP:$port -sTCP:LISTEN). Nothing was started."
            fi
        done
    done
}

# What this run of "up" started, taken back when it does not finish: an environment is up or
# it is not. What was running before stays; .test-env/ and the image stay.
CREATED=()        # container ids
CREATED_NAMES=()  # their names, for the messages
RESTARTED=()
NETWORK_CREATED=0
UP_FINISHED=0

undo_unfinished_up() {
    [ "$UP_FINISHED" = 1 ] && return 0
    local name index=0
    while [ "$index" -lt "${#CREATED[@]}" ]; do
        docker rm --force "${CREATED[$index]}" >/dev/null 2>&1 \
            && printf '  %-18s removed again\n' "${CREATED_NAMES[$index]}" >&2
        index=$((index + 1))
    done
    for name in ${RESTARTED[@]+"${RESTARTED[@]}"}; do
        docker stop "$name" >/dev/null 2>&1 && printf '  %-18s stopped again\n' "$name" >&2
    done
    if [ "$NETWORK_CREATED" = 1 ]; then
        docker network rm "$NETWORK" >/dev/null 2>&1 && printf '  network %s removed again\n' "$NETWORK" >&2
    fi
    return 0
}

cmd_up() {
    require_docker
    preflight
    generate_material
    trap undo_unfinished_up EXIT

    echo "==> Building $IMAGE"
    docker build --quiet --tag "$IMAGE" "$SCRIPT_DIR/image" >/dev/null

    if ! network_exists; then
        docker network create --label "$NETWORK_LABEL" "$NETWORK" >/dev/null
        NETWORK_CREATED=1
    fi

    echo "==> Containers"
    local server
    for server in "${SERVERS[@]}"; do
        start_server "$server"
    done

    echo "==> Waiting for sshd"
    wait_for_servers
    UP_FINISHED=1

    cat <<EOF
==> The test environment is up (user: $TESTER)
  $BIND:2222  termi-test-a      password and public key   hosts test-a, test-pass, test-pw, test-agent
  $BIND:2224  termi-test-a      keyboard-interactive      host  test-kbd
  $BIND:2223  termi-test-jump   jump host                 host  jump
  inner:22        termi-test-inner  only through the jump     host  inner

Generated on this machine in $ENV_DIR
(never committed, never printed):
  tester_password                      the password of $TESTER
  id_plain  id_passphrase  id_agent    key pairs; key_passphrase unlocks id_passphrase
  hostkeys/                            the servers' host keys (the seeded hosts are pinned to them)
  seed-hosts.json                      the hosts the app is seeded with
  profile/                             the app's isolated profile

Next:
  make run-isolated
      the app on that profile, with those hosts
  ssh-add -t 1h "$ENV_DIR/id_agent"
      for the host test-agent; "ssh-add -d" with the same file removes it again
  ssh -F "$ENV_DIR/ssh_config" inner
      the servers without the app (test-a, test-kbd, jump, inner)
  make test-env-down
      when you are done
EOF
}

cmd_down() {
    require_docker
    local server name
    for server in "${SERVERS[@]}"; do
        name="$(container_name "$server")"
        if [ "$(container_state "$server")" = absent ]; then
            printf '  %-18s not there\n' "$name"
        else
            docker rm --force "$name" >/dev/null
            printf '  %-18s removed\n' "$name"
        fi
    done
    if network_exists; then
        if network_is_ours; then
            docker network rm "$NETWORK" >/dev/null
            printf '  network %s removed\n' "$NETWORK"
        else
            printf '  network %s was not created by this script: left alone\n' "$NETWORK"
        fi
    fi
    if [ -d "$ENV_DIR" ]; then
        echo "Kept: $ENV_DIR (password, keys, the app profile). Nothing else was removed;"
        echo "the image $IMAGE stays for the next \"up\"."
    fi
}

cmd_status() {
    require_docker
    local server name ports
    for server in "${SERVERS[@]}"; do
        name="$(container_name "$server")"
        ports="$(docker ps --filter "name=^/$name\$" --format '{{.Ports}}')"
        printf '  %-18s %-8s %s\n' "$name" "$(container_state "$server")" "$ports"
    done
    local port
    for port in 2222 2224 2223; do
        if ssh_answers "$port" 2>/dev/null; then
            printf '  %s:%s  sshd answers\n' "$BIND" "$port"
        else
            printf '  %s:%s  closed\n' "$BIND" "$port"
        fi
    done
    if [ -d "$ENV_DIR" ]; then
        printf '  %s exists' "$ENV_DIR"
        [ -f "$ENV_DIR/seed-hosts.json" ] && printf ' (seed-hosts.json present)'
        [ -d "$ENV_DIR/profile" ] && printf ' (profile present)'
        printf '\n'
        if [ -f "$ENV_DIR/id_agent.pub" ] && ssh-add -L 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$ENV_DIR/id_agent.pub")"; then
            echo "  the agent holds the test key (remove: ssh-add -d \"$ENV_DIR/id_agent\")"
        else
            echo "  the agent does not hold the test key (add: ssh-add -t 1h \"$ENV_DIR/id_agent\")"
        fi
    else
        printf '  %s does not exist (run "up")\n' "$ENV_DIR"
    fi
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    *)      echo "usage: $(basename "$0") up | down | status" >&2; exit 2 ;;
esac
