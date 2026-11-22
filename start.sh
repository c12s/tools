#!/usr/bin/env bash
# start.sh — bring up the c12s control plane.
#
# Safe to re-run, and works both on a clean machine and on top of volumes from
# a previous run (see stop.sh / stop.sh --clean). It:
#   1. builds and starts the compose stack
#   2. applies the scylla schema (idempotent)
#   3. checks vault got unsealed by apollo with tools/vault/api_key.json
#   4. makes sure the test user exists and can log in
#   5. re-seeds the provisioning qcow2 into the artifact server if it is
#      missing (after stop.sh --clean)
#   6. optionally starts dockerized star/starometry nodes (NODES_NUM)
#
# Environment:
#   NODES_NUM   dockerized star nodes to start (default 0 — bootc nodes come
#               from wormhole's libvirt backend; docker nodes would also land
#               in the node pool next to them)
#   C12S_USER / C12S_PASS / C12S_ORG   test user (default e2e / testpass123 / c12s)
#   QCOW2_DIR   where provisioning disks live (default ~/.wormhole/images)
#   C12S_NO_BUILD  1 = skip image builds (same as --no-build); --build overrides
#
# Usage: ./start.sh [--no-build|--build]
#   --no-build  reuse the already-built images (fast path after a reboot)
#   --build     force a rebuild even when C12S_NO_BUILD=1

set -euo pipefail
cd "$(dirname "$0")"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

NODES_NUM="${NODES_NUM:-0}"
C12S_USER="${C12S_USER:-e2e}"
C12S_PASS="${C12S_PASS:-testpass123}"
C12S_ORG="${C12S_ORG:-c12s}"
QCOW2_DIR="${QCOW2_DIR:-$HOME/.wormhole/images}"
GATEWAY="http://localhost:5555"
ARTIFACTS="http://localhost:${SINGULARITY_FILES_HOST_PORT:-8081}"

log()  { printf '[start] %s\n' "$*"; }
fail() { printf '[start] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ./start.sh [--no-build|--build]

  --no-build  reuse the already-built images (fast path after a reboot)
  --build     force a rebuild even when C12S_NO_BUILD=1

C12S_NO_BUILD=1 has the same effect as --no-build.
EOF
}

NO_BUILD=0
case "${C12S_NO_BUILD:-0}" in
    1|true|yes) NO_BUILD=1 ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) NO_BUILD=1 ;;
        --build)    NO_BUILD=0 ;;
        -h|--help)  usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    shift
done

# wait_for <description> <attempts> <sleep-seconds> <command...>
wait_for() {
    local what=$1 attempts=$2 pause=$3 i
    shift 3
    for ((i = 1; i <= attempts; i++)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep "$pause"
    done
    fail "$what not ready after $((attempts * pause))s"
}

# --- vault key file -----------------------------------------------------------
# apollo bind-mounts this file; if it is missing docker would create a
# directory in its place and apollo could neither read nor save the keys.
mkdir -p vault
if [ -d vault/api_key.json ]; then
    rmdir vault/api_key.json
fi
if [ ! -f vault/api_key.json ]; then
    echo '{}' > vault/api_key.json
fi

# --- control plane ------------------------------------------------------------
if [ "$NO_BUILD" = 1 ]; then
    log "skipping image build (--no-build / C12S_NO_BUILD=1)"
else
    log "building control plane images"
    docker compose build || fail "control plane build failed"
fi
log "starting control plane"
docker compose up -d --remove-orphans || fail "docker compose up failed"

scylla_healthy() { [ "$(docker inspect --format='{{.State.Health.Status}}' scylla 2>/dev/null)" = healthy ]; }
log "waiting for scylla"
wait_for "scylla" 60 5 scylla_healthy
docker exec scylla /bin/sh -c "cqlsh -f /scylla_schema.cql" || fail "applying scylla schema failed"

vault_unsealed() {
    docker exec vault vault status -format=json 2>/dev/null | grep -q '"sealed": false'
}
vault_unseal() {
    # apollo unseals only when apollo itself starts, so a vault container
    # restarted on its own stays sealed; unseal with the same key file
    local key
    key=$(python3 -c 'import json;print(json.load(open("vault/api_key.json")).get("unseal_key",""))' 2>/dev/null)
    [ -n "$key" ] && docker exec vault vault operator unseal "$key" >/dev/null 2>&1
    vault_unsealed
}
log "waiting for apollo to initialize/unseal vault"
if ! (wait_for "vault" 15 2 vault_unsealed) 2>/dev/null && ! vault_unseal; then
    fail "vault is still sealed: its data (volume tools_vault_data) and tools/vault/api_key.json \
do not match. Restore the api_key.json written when the volume was initialized, \
or start over with ./stop.sh --clean"
fi

# --- test user ----------------------------------------------------------------
login_ok() {
    curl -sf -X POST "$GATEWAY/apis/core/v1/auth" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$C12S_USER\",\"password\":\"$C12S_PASS\"}" | grep -q '"token"'
}
gateway_up() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/apis/core/v1/auth" \
        -H 'Content-Type: application/json' -d '{}')
    [ "$code" != 000 ] && [ "$code" != 502 ] && [ "$code" != 503 ]
}
log "waiting for the gateway"
wait_for "gateway" 60 2 gateway_up
if ! login_ok; then
    log "registering test user $C12S_USER in org $C12S_ORG"
    curl -s -o /dev/null -X POST "$GATEWAY/apis/core/v1/users" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$C12S_USER\",\"password\":\"$C12S_PASS\",\"org\":\"$C12S_ORG\",\"email\":\"$C12S_USER@c12s.local\",\"name\":\"c12s\",\"surname\":\"e2e\"}"
    wait_for "login as $C12S_USER" 15 2 login_ok
fi
log "test user $C12S_USER can log in"

# --- provisioning disks -------------------------------------------------------
# The artifact volume is wiped by stop.sh --clean; new VMs (wormhole and the
# host's VM reconciler) fetch their qcow2 from here.
listed=$(curl -sf "$ARTIFACTS/artifacts" || echo '[]')
for disk in "$QCOW2_DIR"/edge-base-*.qcow2; do
    [ -f "$disk" ] || continue
    name=$(basename "$disk")
    if ! grep -q "\"$name\"" <<<"$listed"; then
        log "uploading $name to the artifact server"
        curl -sf -X PUT --data-binary "@$disk" "$ARTIFACTS/artifacts/$name" >/dev/null \
            || fail "upload of $name failed"
    fi
done

# --- grafana ------------------------------------------------------------------
docker rm -f grafana >/dev/null 2>&1 || true
docker run -d --name=grafana \
    --restart unless-stopped \
    -p 3000:3000 \
    --network tools_network \
    -v ./grafana/dashboard.yaml:/etc/grafana/provisioning/dashboards/main.yaml \
    -v ./grafana/dashboards:/var/lib/grafana/dashboards \
    -v ./grafana/datasources.yaml:/etc/grafana/provisioning/datasources/main.yaml \
    grafana/grafana >/dev/null

# --- dockerized nodes (optional) ----------------------------------------------
if [ "$NODES_NUM" -gt 0 ]; then
    if [ "$NO_BUILD" = 1 ]; then
        docker image inspect star >/dev/null 2>&1 || fail "star image missing; run without --no-build"
        docker image inspect starometry >/dev/null 2>&1 || fail "starometry image missing; run without --no-build"
    else
        docker build -f ../star/Dockerfile .. -t star
        docker build -f ../starometry/Dockerfile .. -t starometry
    fi
    for ((i = 1; i <= NODES_NUM; i++)); do
        # node ids persist in nodeconfig/ (removed by stop.sh --clean)
        mkdir -p "$(pwd)/nodeconfig/star_$i"
        docker rm -f "star_$i" "starometry_$i" >/dev/null 2>&1 || true
        docker run -d --name "star_$i" --restart unless-stopped \
            --mount type=bind,source="$(pwd)/nodeconfig/star_$i",target="$NODE_ID_DIR_PATH" \
            --env STAR_HOSTNAME="star_$i" \
            --env STAR_PORT="${STAR_PORT}" \
            --env STAR_ADDRESS="${STAR_ADDRESS}" \
            --env NATS_HOSTNAME="${NATS_HOSTNAME}" \
            --env NATS_PORT="${NATS_PORT}" \
            --env NATS_ADDRESS="${NATS_ADDRESS}" \
            --env REGISTRATION_REQ_TIMEOUT_MILLISECONDS="${REGISTRATION_REQ_TIMEOUT_MILLISECONDS}" \
            --env MAX_REGISTRATION_RETRIES="${MAX_REGISTRATION_RETRIES}" \
            --env NODE_ID_DIR_PATH="${NODE_ID_DIR_PATH}" \
            --env NODE_ID_FILE_NAME="${NODE_ID_FILE_NAME}" \
            --env BIND_ADDRESS="10.5.0.$((i + 2))" \
            --env BIND_PORT="${BIND_PORT}" \
            -p "$((STAR_PORT + i - 1)):${STAR_PORT}" \
            --hostname "star_$i" \
            --network=tools_network \
            --ip "10.5.0.$((i + 2))" \
            star:latest >/dev/null
        docker run -d \
            --name "starometry_$i" \
            --hostname "starometry_$i" \
            -p "$((STAROMETRY_HTTP_PORT + i - 1)):${STAROMETRY_HTTP_PORT}" \
            -p "$((STAROMETRY_GRPC_PORT + i - 1)):${STAROMETRY_GRPC_PORT}" \
            --restart always \
            --env NODE_EXPORTER_URL="${NODE_EXPORTER_ADDRESS}" \
            --env NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT}" \
            --env CADVISOR_URL="${CADVISOR_ADDRESS}" \
            --env CADVISOR_PORT="${CADVISOR_PORT}" \
            --env APP_PORT="${STAROMETRY_HTTP_PORT}" \
            --env NATS_PORT="${NATS_PORT}" \
            --env NATS_URL="${NATS_HOSTNAME}" \
            --env GRPC_PORT="${STAROMETRY_GRPC_PORT}" \
            --env APP_METRICS_CRON_TIMER="${METRICS_CRON_TIMER:-15s}" \
            --env APP_METRICS_EXTERNAL_CRON_TIMER="${METRICS_EXTERNAL_CRON_TIMER:-30s}" \
            --mount type=bind,source="$(pwd)/nodeconfig/star_$i",target="$NODE_ID_DIR_PATH" \
            --network tools_network \
            --ip "10.5.1.$((i + 2))" \
            starometry:latest >/dev/null
        log "started star_$i / starometry_$i"
    done
fi

log "control plane up: gateway $GATEWAY, registry localhost:${SINGULARITY_HOST_PORT:-5001}, artifacts $ARTIFACTS"
log "bootc nodes: cd ../wormhole && ./wormhole -c config.host.yaml create (plain node) / ./wormhole -c config.libvirt.yaml create (VM host)"
