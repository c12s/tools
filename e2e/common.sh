#!/usr/bin/env bash
# common.sh — shared helpers for the end-to-end OS-update tests.
#
# Environment (all overridable):
#   GATEWAY, C12S_USER/PASS/ORG, ETCD_CONTAINER, ZOT, SINGULARITY_FILES,
#   HOST_VM_IP, HOST_ID (libvirt host node), CP_HOST, REGISTRY, DISK_REGISTRY,
#   IMAGE_REPO, GOOD_TAG, FLEET_QCOW2, COCKPIT_BIN, RESULTS_DIR.
#
# The scripts drive the control plane through cockpit, observe node state by
# decoding the etcd node records (protoc), and reach nested VMs through the
# libvirt host's serial console (vm_console.py). No node-side instrumentation
# is needed — os_status transitions are the measurement.

set -uo pipefail

EXPERIMENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(dirname "$EXPERIMENTS_DIR")"
REPO_ROOT="$(dirname "$TOOLS_DIR")"
COCKPIT_DIR="$REPO_ROOT/cockpit"
RESULTS_DIR="${RESULTS_DIR:-$EXPERIMENTS_DIR/results}"
TMP_DIR="${TMP_DIR:-${TMPDIR:-/tmp}/c12s-e2e}"

GATEWAY="${GATEWAY:-http://localhost:5555}"
C12S_USER="${C12S_USER:-e2e}"
C12S_PASS="${C12S_PASS:-testpass123}"
C12S_ORG="${C12S_ORG:-c12s}"
ETCD_CONTAINER="${ETCD_CONTAINER:-etcd}"
ZOT="${ZOT:-localhost:5001}"
SINGULARITY_FILES="${SINGULARITY_FILES:-http://localhost:8081}"
HOST_VM_IP="${HOST_VM_IP:-192.168.122.61}"   # VM host (first VM of wormhole config.libvirt.yaml)
CP_HOST="${CP_HOST:-192.168.122.1}"          # control-plane host as the nodes reach it
REGISTRY="${REGISTRY:-$CP_HOST:5001}"        # OS image registry, node-visible
DISK_REGISTRY="${DISK_REGISTRY:-http://$CP_HOST:8081}"  # qcow2 artifact server, node-visible
IMAGE_REPO="${IMAGE_REPO:-$REGISTRY/os/edge-base}"
COCKPIT_BIN="${COCKPIT_BIN:-$HOME/.cache/c12s/cockpit}"
FLEET_QCOW2="${FLEET_QCOW2:-edge-base-v4.0.qcow2}"
GOOD_TAG="${GOOD_TAG:-v4.1}"
GOOD_VERSION="${GOOD_VERSION:-$GOOD_TAG}"

HOST_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes c12s@$HOST_VM_IP"
mkdir -p "$TMP_DIR" "$RESULTS_DIR"

# The libvirt host's node id changes whenever it re-enrolls, so read it from
# the host itself instead of hardcoding it.
if [ -z "${HOST_ID:-}" ]; then
  HOST_ID=$($HOST_SSH 'cat /var/lib/c12s/nodeid' 2>/dev/null) || HOST_ID=""
fi

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- cockpit ---------------------------------------------------------------

ensure_cockpit() {
  local stale
  stale=$(find "$COCKPIT_DIR/cmd" "$COCKPIT_DIR/model" "$COCKPIT_DIR/main.go" -newer "$COCKPIT_BIN" 2>/dev/null | head -1)
  if [ ! -x "$COCKPIT_BIN" ] || ! head -c4 "$COCKPIT_BIN" 2>/dev/null | grep -q ELF || [ -n "$stale" ]; then
    mkdir -p "$(dirname "$COCKPIT_BIN")"
    (cd "$COCKPIT_DIR" && go build -o "$COCKPIT_BIN" . && chmod +x "$COCKPIT_BIN") || fail "cockpit build failed"
  fi
}

login() {
  local token
  token=$(curl -sf -X POST "$GATEWAY/apis/core/v1/auth" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$C12S_USER\",\"password\":\"$C12S_PASS\"}" \
    | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])') || fail "login failed"
  printf '%s' "$token" > "$COCKPIT_DIR/token.txt"
}

cockpit() { (cd "$COCKPIT_DIR" && "$COCKPIT_BIN" "$@"); }

# cockpit ... with rate-limit retry (heliosphere throttles per user/method)
cockpit_retry() {
  local tries=8 out
  while [ "$tries" -gt 0 ]; do
    if out=$(cockpit "$@" 2>&1); then echo "$out"; return 0; fi
    if echo "$out" | grep -qi 'rate limit'; then sleep 15; tries=$((tries - 1)); continue; fi
    echo "$out" >&2
    return 1
  done
  echo "rate limit never cleared" >&2
  return 1
}

image_update() { # <nodeid> <image-ref> <digest>
  local tries=8 out
  while [ "$tries" -gt 0 ]; do
    if out=$(cockpit image update --node-id "$1" --image-ref "$2" --digest "$3" 2>&1); then
      echo "$out"
      return 0
    fi
    # an unacknowledged update still succeeds: the desired image is recorded
    # in Magnetar and the node pulls it when it is back
    if echo "$out" | grep -qi 'rate limit'; then
      sleep 15
    else
      echo "$out" >&2
      return 1
    fi
    tries=$((tries - 1))
  done
  echo "image update never accepted: $out" >&2
  return 1
}

# image_apply <spec-file> [--dry-run] [--force]
# Declarative front end: a HostImageSpec names nodes by id with an image each
# (and VM sets for hosts); apply updates only those nodes, canary first. The
# spec is a client-side document; the control plane stores per-node intent.
image_apply() {
  local spec=$1; shift
  cockpit_retry image apply --spec "$spec" "$@"
}

# --- node state (etcd -> protoc text) ---------------------------------------

node_decode() {
  local id=$1 key
  key=$(docker exec "$ETCD_CONTAINER" etcdctl get nodes --prefix --keys-only 2>/dev/null | grep "/$id$" | head -1)
  [ -n "$key" ] || return 1
  docker exec "$ETCD_CONTAINER" etcdctl get "$key" --print-value-only > "$TMP_DIR/node.bin" 2>/dev/null || return 1
  [ -s "$TMP_DIR/node.bin" ] || return 1
  # etcdctl appends a newline; protoc treats it as a truncated field
  if [ "$(tail -c 1 "$TMP_DIR/node.bin" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then
    truncate -s -1 "$TMP_DIR/node.bin"
  fi
  protoc --decode=proto.Node -I "$REPO_ROOT/magnetar/pkg/api/proto" magnetar_model.proto < "$TMP_DIR/node.bin" 2>/dev/null
}

node_phase() {
  node_decode "$1" | awk '/^osStatus/{f=1} f && /phase:/{gsub(/"/,"",$2); print $2; exit}'
}

node_booted_digest() {
  node_decode "$1" | awk '/bootedDigest:/{gsub(/"/,"",$2); print $2; exit}'
}

node_desired_digest() { # declared in Magnetar; empty = none
  docker exec "$ETCD_CONTAINER" etcdctl get "desired_os/$1" --print-value-only 2>/dev/null \
    | grep -o '"Digest":"[^"]*"' | cut -d'"' -f4
}

vm_booted_digest() { # <vm-name> -> digest bootc reports on the node itself
  vm_run "$1" 'sudo bootc status --format=humanreadable | grep "Booted image"' 2>/dev/null \
    | grep -o 'sha256:[0-9a-f]\{64\}' | head -1
}

node_booted_image() {
  node_decode "$1" | awk '/bootedImage:/{gsub(/"/,"",$2); print $2; exit}'
}

node_attempt_result() {
  node_decode "$1" | awk '/result:/{gsub(/"/,"",$2); print $2; exit}'
}

# wait_for_phase <nodeid> <phase> <timeout> [poll] -> prints "elapsed_s notes"
# TRANSITIONS (global) collects "123s:switching 145s:degraded ..." observed.
wait_for_phase() {
  local id=$1 target=$2 timeout=${3:-480} poll=${4:-2}
  local start elapsed phase last=""
  start=$(date +%s)
  TRANSITIONS=""
  while :; do
    elapsed=$(( $(date +%s) - start ))
    phase=$(node_phase "$id" || true)
    if [ -n "$phase" ] && [ "$phase" != "$last" ]; then
      TRANSITIONS+="${elapsed}s:${phase} "
      last=$phase
    fi
    if [ "$phase" = "$target" ]; then
      echo "$elapsed"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "$elapsed"
      return 1
    fi
    sleep "$poll"
  done
}

# wait_for_digest <nodeid> <digest> <timeout> -> healthy AND booted digest match
wait_for_digest() {
  local id=$1 digest=$2 timeout=${3:-600} start now phase bd
  start=$(date +%s)
  while :; do
    now=$(( $(date +%s) - start ))
    phase=$(node_phase "$id" || true)
    bd=$(node_booted_digest "$id" || true)
    if [ "$bd" = "$digest" ] && [ "$phase" = "healthy" ]; then
      echo "$now"
      return 0
    fi
    if [ "$now" -ge "$timeout" ]; then
      echo "$now"
      return 1
    fi
    sleep 3
  done
}

# --- nested VM access (serial console on the libvirt host) ------------------

vm_run() { # <vm-name> <shell command...>; VM_RUN_TIMEOUT overrides the 90s default
  local name=$1; shift
  local b64
  b64=$(printf '%s' "$*" | base64 -w0)
  $HOST_SSH "python3 - c12s-vm-$name $b64 ${VM_RUN_TIMEOUT:-90}" < "$EXPERIMENTS_DIR/vm_console.py"
}

vm_nodeid() { # <vm-name> -> uuid (empty while not enrolled)
  vm_run "$1" 'cat /var/lib/c12s/nodeid 2>/dev/null || true' 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1
}

# --- images -----------------------------------------------------------------

ensure_star_binary() {
  (cd "$REPO_ROOT/star" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$TOOLS_DIR/bootc/star" ./cmd) \
    || fail "star build failed"
  (cd "$REPO_ROOT/starometry" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$TOOLS_DIR/bootc/starometry" ./cmd) \
    || fail "starometry build failed"
}

zot_digest() { # <tag>
  curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$ZOT/v2/os/edge-base/manifests/$1" | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# build_image <tag> <version> [containerfile] [base-ref]
# Reuses an existing tag in Zot unless FORCE_BUILD=1. Prints the digest.
build_image() {
  local tag=$1 version=$2 cfile=${3:-Containerfile.bootc} base=${4:-} digest
  digest=$(zot_digest "$tag")
  if [ -n "$digest" ] && [ -z "${FORCE_BUILD:-}" ]; then
    echo "$digest"
    return 0
  fi
  ensure_star_binary
  local args=(--build-arg "OS_VERSION=$version")
  [ -n "$base" ] && args+=(--build-arg "BASE=$base")
  docker build -f "$TOOLS_DIR/bootc/$cfile" "${args[@]}" \
    -t "localhost:5001/os/edge-base:$tag" "$TOOLS_DIR/bootc" >/dev/null 2>&1 || fail "docker build $tag failed"
  podman pull docker-daemon:"localhost:5001/os/edge-base:$tag" >/dev/null 2>&1 || fail "podman pull $tag failed"
  podman push --tls-verify=false "localhost:5001/os/edge-base:$tag" >/dev/null 2>&1 || fail "podman push $tag failed"
  digest=$(zot_digest "$tag")
  [ -n "$digest" ] || fail "no digest after pushing $tag"
  log "built image $tag ($digest)"
  echo "$digest"
}

ensure_good_image() { build_image "$GOOD_TAG" "$GOOD_VERSION"; }

# <GOOD_TAG>-alt: same build as the good image with a different version
# stamp, so it is a distinct digest that was never deployed (E4 drift, E5)
alt_image() { build_image "$GOOD_TAG-alt" "$GOOD_TAG-alt"; }

broken_image() { # <n> -> prints digest; builds <GOOD_TAG>-broken-<n>
  build_image "$GOOD_TAG-broken-$1" "$GOOD_TAG-broken-$1" Containerfile.broken "localhost:5001/os/edge-base:$GOOD_TAG"
}

# --- fleet ------------------------------------------------------------------

ensure_os_update_policy() { # <nodeid>
  local id=$1 file="$TMP_DIR/policy-$1.yaml"
  cat > "$file" <<EOF
objectScope:
  id: "$id"
  kind: "node"
permission:
  condition:
    expression: ""
  kind: "ALLOW"
  name: "os.update"
subjectScope:
  id: "$C12S_USER"
  kind: "user"
EOF
  cockpit_retry create policies --path "$file" >/dev/null 2>&1 || log "policy for $id may already exist"
}

# fleet_claim: move every node in the pool into the experiment org (the
# libvirt host and its VMs enroll unclaimed; assumes no other pool nodes)
fleet_claim() {
  if [ -z "$(docker exec "$ETCD_CONTAINER" etcdctl get nodes/pool --prefix --keys-only 2>/dev/null | grep -v '^$')" ]; then
    return 0
  fi
  cockpit_retry claim nodes --org "$C12S_ORG" --query 'cpu-cores > 0' >/dev/null || fail "claiming pool nodes failed"
  log "claimed pool nodes into $C12S_ORG"
}

fleet_set() { # <vm-count>
  local n=${1:-2} digest spec vms="" i
  [ -n "$HOST_ID" ] || fail "HOST_ID unknown: libvirt host $HOST_VM_IP unreachable or not enrolled (set HOST_ID to override)"
  digest=$(curl -sf "$SINGULARITY_FILES/artifacts/$FLEET_QCOW2/sha256") || fail "fleet qcow2 $FLEET_QCOW2 not on the artifact server"
  for i in $(seq 1 "$n"); do
    vms+="{\"name\":\"vm-0$i\",\"qcow2Url\":\"$DISK_REGISTRY/artifacts/$FLEET_QCOW2\",\"digest\":\"$digest\",\"vcpus\":1,\"memoryMb\":1024},"
  done
  spec="{\"vms\":[${vms%,}]}"
  cockpit_retry vms set --host "$HOST_ID" --spec "$spec" >/dev/null || fail "vms set failed"
  log "desired fleet of $n VMs declared on host $HOST_ID"
}

# fleet_wait <n> [timeout] -> BMAP["vm-01"]=nodeid ... (bash 4 assoc via global)
fleet_wait() {
  local n=${1:-2} timeout=${2:-420} i id start
  start=$(date +%s)
  for i in $(seq 1 "$n"); do
    id=""
    while [ -z "$id" ]; do
      id=$(vm_nodeid "vm-0$i" || true)
      [ -n "$id" ] && break
      [ $(( $(date +%s) - start )) -ge "$timeout" ] && fail "vm-0$i did not enroll within ${timeout}s"
      sleep 10
    done
    declare -g "VM_NODE_$i=$id"
    log "vm-0$i -> $id"
  done
}

fleet_ready() { # <n>: wait until every fleet node is healthy, then create policies
  local n=${1:-2} i id
  for i in $(seq 1 "$n"); do
    id=$(eval echo \$VM_NODE_$i)
    local elapsed
    elapsed=$(wait_for_phase "$id" healthy 600 3) || fail "node $id not healthy after ${elapsed}s"
    ensure_os_update_policy "$id"
  done
  # the libvirt host is a bootc node too; its id changes when it re-registers
  ensure_os_update_policy "$HOST_ID"
  login  # permissions are baked into the JWT at login time
  log "fleet ready (policies created, re-logged in)"
}

# fleet_pin <n> <digest>: declare the good image as every node's desired OS.
# Fresh VMs have no desired image, so without this a drifted node would still
# count as healthy. A no-op switch when the node already booted it.
fleet_pin() {
  local n=${1:-2} digest=$2 i id
  for i in $(seq 1 "$n"); do
    id=$(eval echo \$VM_NODE_$i)
    image_update "$id" "$IMAGE_REPO:$GOOD_TAG" "$digest" >/dev/null || fail "pinning $id to $GOOD_TAG failed"
    wait_for_digest "$id" "$digest" 600 >/dev/null || fail "node $id not healthy on $GOOD_TAG"
  done
  log "fleet pinned to $GOOD_TAG"
}

fleet_save() { # <n>
  local n=${1:-2} i
  : > "$RESULTS_DIR/fleet.env"
  for i in $(seq 1 "$n"); do
    echo "VM_NODE_$i=$(eval echo \$VM_NODE_$i)" >> "$RESULTS_DIR/fleet.env"
    echo "VM_NAME_$i=vm-0$i" >> "$RESULTS_DIR/fleet.env"
  done
  echo "HOST_ID=$HOST_ID" >> "$RESULTS_DIR/fleet.env"
  log "fleet saved to $RESULTS_DIR/fleet.env"
}

fleet_load() {
  [ -f "$RESULTS_DIR/fleet.env" ] || fail "no $RESULTS_DIR/fleet.env — run setup-fleet.sh first"
  # shellcheck disable=SC1091
  source "$RESULTS_DIR/fleet.env"
  # the pinned digest belongs to the tag the fleet was set up with; a run
  # with another GOOD_TAG must not restore nodes to it
  [ "${FLEET_GOOD_TAG:-}" = "$GOOD_TAG" ] || unset GOOD_DIGEST
  VM_COUNT=$(grep -c '^VM_NODE_' "$RESULTS_DIR/fleet.env")
  [ "$VM_COUNT" -gt 0 ] || fail "fleet.env has no nodes"
}

# --- results ----------------------------------------------------------------

results_file() { echo "$RESULTS_DIR/$1.csv"; }

record() { # <file> <line>
  echo "$2" >> "$(results_file "$1")"
}

# The libvirt host blocks guest egress except to the control plane (E5).
airgap_on() {
  $HOST_SSH "sudo nft insert rule ip libvirt_network guest_output iif \\\"virbr-c12s\\\" ip daddr != $CP_HOST counter drop comment \\\"c12s-airgap\\\"" || fail "could not enable air gap"
  log "air gap enabled on $(hostname 2>/dev/null || echo host): guest egress -> only $CP_HOST"
}

airgap_off() {
  $HOST_SSH 'for h in $(sudo nft -a list chain ip libvirt_network guest_output | awk "/c12s-airgap/{print \$NF}"); do sudo nft delete rule ip libvirt_network guest_output handle $h; done' >/dev/null 2>&1 || true
  log "air gap disabled"
}
