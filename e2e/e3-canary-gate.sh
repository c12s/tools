#!/usr/bin/env bash
# E3 — canary rollout with a health gate.
#
# Drives `cockpit image rollout`, the platform's canary-gated rollout:
#   1. roll a deliberately broken image out with CANARY first and PROD as
#      target — greenboot must roll the canary back and the rollout must stop
#      (non-zero exit) without updating PROD;
#   2. roll the good image out the same way, which restores the canary and
#      exercises the success path (canary healthy, soak, then target).
# Usage: e3-canary-gate.sh [canary-node] [prod-node]

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
[ "$VM_COUNT" -ge 2 ] || fail "E3 needs at least 2 nodes (have $VM_COUNT)"
ensure_cockpit
login

CANARY="${1:-$VM_NODE_1}"
PROD="${2:-$VM_NODE_2}"
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"
REGISTRY_REF=$IMAGE_REPO

BROKEN_TAG="$GOOD_TAG-broken-canary"
BROKEN_DIGEST=$(build_image "$BROKEN_TAG" "$BROKEN_TAG" Containerfile.broken "localhost:5001/os/edge-base:$GOOD_TAG")
log "broken canary image digest: $BROKEN_DIGEST"

rollout() { # <tag> <digest> -> rollout exit code; output in $TMP_DIR/e3-rollout.log
  cockpit image rollout --org "$C12S_ORG" --canary "$CANARY" --nodes "$PROD" \
    --image-ref "$REGISTRY_REF:$1" --digest "$2" --poll 5s --timeout 20m \
    > "$TMP_DIR/e3-rollout.log" 2>&1
  local rc=$?
  sed 's/^/    /' "$TMP_DIR/e3-rollout.log" >&2
  return $rc
}

record e3-canary "role,node,phase,digest,result"

log "rollout of $BROKEN_TAG: canary $CANARY, target $PROD"
T0=$(date +%s)
if rollout "$BROKEN_TAG" "$BROKEN_DIGEST"; then
  record e3-canary "canary,$CANARY,$(node_phase "$CANARY"),$BROKEN_DIGEST,promoted"
  fail "the rollout promoted a broken image"
fi
ELAPSED=$(( $(date +%s) - T0 ))
CANARY_PHASE=$(node_phase "$CANARY")
if [ "$CANARY_PHASE" = "rolled_back" ]; then
  log "gate held: canary rolled back, rollout stopped at +${ELAPSED}s"
  record e3-canary "canary,$CANARY,rolled_back,$BROKEN_DIGEST,stopped ${ELAPSED}s"
else
  record e3-canary "canary,$CANARY,$CANARY_PHASE,$BROKEN_DIGEST,stopped-other"
  fail "rollout stopped, but canary phase is $CANARY_PHASE (expected rolled_back)"
fi

PROD_PHASE=$(node_phase "$PROD")
PROD_DIGEST=$(node_booted_digest "$PROD")
if [ "$PROD_PHASE" = "healthy" ] && [ "$PROD_DIGEST" = "$GOOD_DIGEST" ]; then
  log "production node untouched: healthy on $GOOD_TAG"
  record e3-canary "production,$PROD,$PROD_PHASE,$PROD_DIGEST,untouched"
else
  record e3-canary "production,$PROD,$PROD_PHASE,$PROD_DIGEST,changed"
  fail "production node was affected: phase=$PROD_PHASE digest=$PROD_DIGEST"
fi

log "rollout of $GOOD_TAG: restores the canary, then the target"
T0=$(date +%s)
rollout "$GOOD_TAG" "$GOOD_DIGEST" || fail "rollout of the good image failed"
ELAPSED=$(( $(date +%s) - T0 ))
log "canary and target healthy on $GOOD_TAG at +${ELAPSED}s"
record e3-canary "canary,$CANARY,healthy,$GOOD_DIGEST,restored ${ELAPSED}s"
log "E3 gate conclusion: the rollout stopped at the canary; production never received the bad image"
