#!/usr/bin/env bash
# stop.sh [--clean] — stop the c12s control plane. Safe to re-run.
#
# Default keeps all volumes (etcd nodes, scylla users, vault, registry images,
# artifacts), so ./start.sh resumes where you left off.
# --clean also deletes the volumes and dockerized node ids: the next start is
# from scratch (apollo re-initializes vault and rewrites vault/api_key.json,
# start.sh re-creates the test user and re-uploads the qcow2). Enrolled bootc nodes keep their node id and re-register
# by themselves.
#
# libvirt VMs (wormhole) are left running — edge nodes outlive the CP.

set -uo pipefail
cd "$(dirname "$0")"

CLEAN=0
case "${1:-}" in
    --clean) CLEAN=1 ;;
    "") ;;
    *) echo "usage: $0 [--clean]" >&2; exit 2 ;;
esac

log() { printf '[stop] %s\n' "$*"; }

nodes=$(docker ps -a --format '{{.Names}}' | grep -E '^(star|starometry)_[0-9]+$' || true)
if [ -n "$nodes" ]; then
    log "removing dockerized nodes: $(echo $nodes)"
    # shellcheck disable=SC2086
    docker rm -f $nodes >/dev/null
fi
docker rm -f grafana tardis-grafana >/dev/null 2>&1 || true

if [ "$CLEAN" = 1 ]; then
    log "stopping control plane and deleting its volumes"
    docker compose down -v --remove-orphans
    rm -rf ./nodeconfig
else
    log "stopping control plane (volumes kept; use --clean to wipe)"
    docker compose down --remove-orphans
fi
