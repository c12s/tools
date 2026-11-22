#!/usr/bin/env bash
# E2 — convergence time.
#
# Declare the good image on all fleet nodes as simultaneously as the control
# plane allows (sequential cockpit calls; the user rate limiter spaces them),
# then measure until every node reports phase=healthy with the new digest.

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

TARGET_TAG="${1:-$GOOD_TAG}"
TARGET_DIGEST=$(zot_digest "$TARGET_TAG") || fail "image $TARGET_TAG not in Zot"

record e2-convergence "node,old_digest,sent_s,healthy_s,result"
log "declaring $TARGET_TAG on $VM_COUNT nodes"

T0=$(date +%s)
declare -A SENT
for i in $(seq 1 "$VM_COUNT"); do
  id=$(eval echo \$VM_NODE_$i)
  old=$(node_booted_digest "$id")
  if [ "$old" = "$TARGET_DIGEST" ]; then
    log "node $id already on $TARGET_TAG, skipping"
    SENT[$id]=$(( $(date +%s) - T0 ))
    record e2-convergence "$id,$old,$(( $(date +%s) - T0 )),0,already"
    continue
  fi
  image_update "$id" "$IMAGE_REPO:$TARGET_TAG" "$TARGET_DIGEST" >/dev/null || fail "update failed for $id"
  SENT[$id]=$(( $(date +%s) - T0 ))
  log "update sent to $id at +${SENT[$id]}s"
done

FAILED=0
for i in $(seq 1 "$VM_COUNT"); do
  id=$(eval echo \$VM_NODE_$i)
  old=$(node_booted_digest "$id")
  if ELAPSED=$(wait_for_digest "$id" "$TARGET_DIGEST" 900); then
    log "node $id healthy on $TARGET_TAG at +${ELAPSED}s"
    record e2-convergence "$id,$old,${SENT[$id]},$ELAPSED,ok"
  else
    log "node $id TIMED OUT after ${ELAPSED}s"
    record e2-convergence "$id,$old,${SENT[$id]},$ELAPSED,timeout"
    FAILED=1
  fi
done

TOTAL=$(( $(date +%s) - T0 ))
log "all-nodes convergence: ${TOTAL}s (last command sent at +$(for i in $(seq 1 $VM_COUNT); do echo ${SENT[$(eval echo \$VM_NODE_$i)]}; done | sort -n | tail -1)s)"
[ "$FAILED" = 0 ] || fail "not all nodes converged"
