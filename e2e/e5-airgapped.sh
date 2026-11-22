#!/usr/bin/env bash
# E5 — air-gapped update.
#
# Guest egress on the libvirt host is blocked except to $CP_HOST (the CP
# / Zot / artifact server), then the node is updated. Success proves the
# update used Singularity as the only image source; an external TCP probe
# proves the block is real while the update runs.

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

NODE="${1:-$VM_NODE_1}"
NAME="${2:-$VM_NAME_1}"
TARGET_TAG="${3:-${GOOD_TAG}-alt}"
if [ "$TARGET_TAG" = "$GOOD_TAG-alt" ]; then TARGET_DIGEST=$(alt_image); else TARGET_DIGEST=$(zot_digest "$TARGET_TAG"); fi
[ -n "$TARGET_DIGEST" ] || fail "image $TARGET_TAG not in Zot"
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"

record e5-airgapped "node,target,egress,accepted_s,healthy_s,transitions"
airgap_on
trap airgap_off EXIT

log "external egress probe from $NAME (expect EXT_BLOCKED)..."
EGRESS=$(vm_run "$NAME" 'timeout 5 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null && echo EXT_OK || echo EXT_BLOCKED' 2>/dev/null | tail -1)
log "egress probe: $EGRESS"

CURRENT=$(node_booted_digest "$NODE")
if [ "$CURRENT" = "$TARGET_DIGEST" ]; then
  log "node already on $TARGET_TAG; the update is a no-op (pick another target for a switch)"
fi

T0=$(date +%s)
image_update "$NODE" "$IMAGE_REPO:$TARGET_TAG" "$TARGET_DIGEST" >/dev/null || fail "update command failed"
T_ACCEPTED=$(( $(date +%s) - T0 ))

if ELAPSED=$(wait_for_digest "$NODE" "$TARGET_DIGEST" 600); then
  log "air-gapped update complete in ${ELAPSED}s (accepted in ${T_ACCEPTED}s)"
  record e5-airgapped "$NODE,$TARGET_TAG,$EGRESS,$T_ACCEPTED,$ELAPSED,ok"
else
  record e5-airgapped "$NODE,$TARGET_TAG,$EGRESS,$T_ACCEPTED,$ELAPSED,timeout"
  fail "node did not reach $TARGET_TAG within ${ELAPSED}s"
fi
