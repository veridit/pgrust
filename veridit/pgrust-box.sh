#!/usr/bin/env bash
# A rented Hetzner build server for the Veridit pgrust fork: building pgrust
# (about 3 million lines of Rust) and running SQL Saga's tests against it,
# away from the developer's laptop. Modelled on statbus ops/bench-box.sh, but
# the box is kept between sessions: its cargo target directory is the build
# cache, and deleting the box throws that cache away.
#
#   veridit/pgrust-box.sh up       create the server and prepare it (or show it
#                                  if it exists): build tools, the pinned Rust
#                                  toolchain, a clone of the fork
#   veridit/pgrust-box.sh sync [branch]
#                                  fetch the branch (default veridit-dev) on the
#                                  box and check it out. Push from the laptop first.
#   veridit/pgrust-box.sh build [cargo args...]
#                                  run cargo build on the box, detached, logged
#                                  with its wall time (default: --release)
#   veridit/pgrust-box.sh run <command...>
#                                  run any command in the box's checkout, detached
#   veridit/pgrust-box.sh progress the running job's log so far
#   veridit/pgrust-box.sh stop     end the running job
#   veridit/pgrust-box.sh results  copy job logs to tmp/pgrust-box/ here
#   veridit/pgrust-box.sh ssh      log in as the build user
#   veridit/pgrust-box.sh status   (or info) the box: address, type, created
#   veridit/pgrust-box.sh down     delete it (billing stops, the cache goes too)
#
# Settings come from .env at the repository root (git-ignored, never committed).
# See veridit/.env.example. HCLOUD_TOKEN is required.
#
# Cost (Falkenstein, gross, 2026-11-13): cx53 (16 shared vCPU, 32 GB, 320 GB)
# about EUR 0.06 per hour, at most about EUR 37 per month. ccx43 (16 dedicated,
# 64 GB) about EUR 0.55 per hour. Shared cores are fine for building: build
# speed does not need the stable timings a benchmark does, and dedicated cores
# count against the project's limit shared with StatBus's bench box and release
# ladder. Timing measurements of StatBus imports belong on the bench box.

# The whole script is one block, so bash reads it completely before running:
# editing this file during a long build changes nothing for the running copy.
{
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/.env" ] || { echo "Missing $ROOT/.env; copy veridit/.env.example and fill in HCLOUD_TOKEN" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a
: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required in .env}"
export HCLOUD_TOKEN

name=pgrust-box
type=${PGRUST_BOX_TYPE:-cx53}
image=ubuntu-26.04
location=${PGRUST_BOX_LOCATION:-fsn1}
ssh_key=${PGRUST_BOX_SSH_KEY:-jorgen@veridit.no}
branch_default=${PGRUST_BOX_BRANCH:-veridit-dev}
label=veridit-purpose=pgrust-box
user=build
repo=https://github.com/veridit/pgrust.git
results="$ROOT/tmp/pgrust-box"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LANGUAGE

describe() { hcloud server describe "$name" -o json 2>/dev/null || true; }

# A same-name server that is not labelled as ours is someone else's: refuse.
require_ours() {
    [ "$(jq -r '.labels["veridit-purpose"] // empty' <<<"$1")" = pgrust-box ] \
        || { echo "REFUSE: server '$name' exists but is not labelled $label" >&2; exit 1; }
}

box_ip() {
    if [ -z "${BOX_IP:-}" ]; then
        local server
        server=$(describe)
        [ -n "$server" ] || { echo "No server '$name'; run: veridit/pgrust-box.sh up" >&2; exit 1; }
        require_ours "$server"
        BOX_IP=$(jq -er '.public_net.ipv4.ip' <<<"$server")
    fi
    echo "$BOX_IP"
}

ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
box() { local who=$1 ip; shift; ip=$(box_ip); ssh "${ssh_opts[@]}" "$who@$ip" "$@"; }

# A script fed to "bash -s" on stdin is read by the first command in it that
# reads stdin, so it goes over as a file first (as in bench-box.sh).
box_script() {
    local who=$1 ip f; shift
    ip=$(box_ip); f=pgrust-step-$$.sh
    ssh "${ssh_opts[@]}" "$who@$ip" "cat > /tmp/$f"
    ssh "${ssh_opts[@]}" "$who@$ip" "bash -euo pipefail /tmp/$f < /dev/null; rc=\$?; rm -f /tmp/$f; exit \$rc"
}

wait_for_ssh() {
    local ip=$1 i
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    for ((i = 0; i < 90; i++)); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$ip" 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    echo "SSH as root did not answer on $ip within 3 minutes" >&2
    exit 1
}

prepare() {
    box_script root <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q > /dev/null
# Build tools for pgrust and its C dependencies (openssl-src, bindgen, ICU).
apt-get install -y -q build-essential clang lld pkg-config cmake git curl jq \
    libssl-dev libicu-dev libreadline-dev zlib1g-dev bison flex perl python3 \
    rsync tmux > /dev/null
id $user > /dev/null 2>&1 || useradd -m -s /bin/bash $user
install -d -m 0700 -o $user -g $user /home/$user/.ssh
cp /root/.ssh/authorized_keys /home/$user/.ssh/authorized_keys
chown $user:$user /home/$user/.ssh/authorized_keys
EOF
    box_script "$user" <<EOF
set -euo pipefail
[ -x ~/.cargo/bin/rustup ] || curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none > /dev/null
. ~/.cargo/env
[ -d ~/pgrust/.git ] || git clone -q $repo ~/pgrust
cd ~/pgrust
git fetch -q origin
git checkout -q $branch_default 2>/dev/null || git checkout -q -b $branch_default origin/$branch_default
# rust-toolchain.toml pins the version; this installs it.
rustup show active-toolchain > /dev/null 2>&1 || rustup toolchain install > /dev/null
echo "checkout \$(git rev-parse --short HEAD) on \$(git branch --show-current), \$(rustc --version)"
EOF
}

show() {
    local server=$1
    cat <<EOF
Box:      $name, $(jq -r '.public_net.ipv4.ip' <<<"$server") ($type, $image, $location), created $(jq -r '.created' <<<"$server")
Log in:   veridit/pgrust-box.sh ssh
Build:    veridit/pgrust-box.sh build
EOF
}

# A detached job on the box: its own session, every stream redirected, so the
# ssh returns at once and the job outlives it. Writes ~/jobs/<id>/job.log.
detach() {
    local id cmd
    id=$(date -u +%Y%m%dT%H%M%SZ)
    cmd=$(printf '%q ' "$@")
    if box "$user" 'pgrep -f "jobs/[j]ob.sh" > /dev/null'; then
        echo "REFUSE: a job is running on the box. See: veridit/pgrust-box.sh progress; end it with: veridit/pgrust-box.sh stop" >&2
        exit 1
    fi
    box "$user" "mkdir -p ~/jobs/$id && cat > ~/jobs/job.sh" <<'JOB'
set -uo pipefail
id=$1; shift
out=~/jobs/$id
exec > >(tee -a "$out/job.log") 2>&1
. ~/.cargo/env
cd ~/pgrust
echo "== job $id start $(date -u +%FT%TZ) commit $(git rev-parse --short HEAD) $(nproc) cores $(free -g | awk '/^Mem:/ {print $2}') GB"
echo "== command: $*"
t0=$(date +%s)
bash -c "$*"
rc=$?
echo "== job $id end $(date -u +%FT%TZ) exit $rc wall_s $(( $(date +%s) - t0 )) peak load $(cut -d' ' -f1-3 /proc/loadavg)"
exit $rc
JOB
    box "$user" "setsid bash ~/jobs/job.sh $id $(printf '%q' "$cmd") > /dev/null 2>&1 < /dev/null & echo started $id"
    echo "Follow:  veridit/pgrust-box.sh progress     Collect: veridit/pgrust-box.sh results"
}

case "${1:-}" in
up)
    server=$(describe)
    if [ -z "$server" ]; then
        hcloud server create --name "$name" --type "$type" --image "$image" \
            --location "$location" --ssh-key "$ssh_key" --label "$label" >/dev/null
        server=$(describe)
    fi
    require_ours "$server"
    BOX_IP=$(jq -er '.public_net.ipv4.ip' <<<"$server")
    wait_for_ssh "$BOX_IP"
    prepare
    show "$server"
    ;;
sync)
    branch=${2:-$branch_default}
    [[ "$branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Not a branch name: $branch" >&2; exit 2; }
    box "$user" "cd ~/pgrust && git fetch -q origin && git checkout -q -B $branch origin/$branch && echo \"at \$(git rev-parse --short HEAD) on $branch\""
    ;;
build)
    shift
    [ "$#" -gt 0 ] || set -- --release
    detach cargo build "$@"
    ;;
run)
    shift
    [ "$#" -gt 0 ] || { echo "Usage: veridit/pgrust-box.sh run <command...>" >&2; exit 2; }
    detach "$@"
    ;;
progress)
    box "$user" 'f=$(ls -td ~/jobs/*/ 2>/dev/null | head -1); [ -n "$f" ] || { echo "No job yet."; exit 0; }; echo "$f"; tail -40 "$f/job.log"; pgrep -f "jobs/[j]ob.sh" >/dev/null && echo "(running, load $(cut -d" " -f1-3 /proc/loadavg))" || echo "(not running)"'
    ;;
stop)
    box "$user" 'sids=$(ps -eo sid=,args= | awk "/jobs\/[j]ob.sh/ {print \$1}" | sort -u); [ -n "$sids" ] || { echo "Nothing running."; exit 0; }; for s in $sids; do pkill -TERM -s "$s"; done; sleep 2; for s in $sids; do pkill -KILL -s "$s" 2>/dev/null; done; echo "Stopped session(s): $sids"'
    ;;
results)
    ip=$(box_ip)
    mkdir -p "$results"
    rsync -a -e "ssh ${ssh_opts[*]}" "$user@$ip:jobs/" "$results/" --exclude job.sh
    latest=$(ls -td "$results"/*/ 2>/dev/null | head -1)
    echo "Copied to $results${latest:+; latest: $latest}"
    [ -n "$latest" ] && tail -20 "$latest/job.log"
    ;;
ssh|connect)
    ssh -o StrictHostKeyChecking=accept-new "$user@$(box_ip)"
    ;;
down)
    server=$(describe)
    [ -n "$server" ] || { echo "No server '$name'; nothing to delete."; exit 0; }
    require_ours "$server"
    ip=$(jq -er '.public_net.ipv4.ip' <<<"$server")
    hcloud server delete "$name" >/dev/null
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    echo "Deleted $name ($ip). Billing has stopped; the build cache is gone."
    ;;
status|info)
    server=$(describe)
    [ -n "$server" ] || { echo "No server '$name'."; exit 0; }
    require_ours "$server"
    show "$server"
    ;;
*)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 2
    ;;
esac
exit
}
