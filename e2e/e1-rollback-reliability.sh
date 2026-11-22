#!/usr/bin/env bash
# E1 — rollback reliability.
#
# Repeat N times: offer a distinct broken image (unique digest, because the
# node's loop guard never retries a known-bad digest), let greenboot roll it
# back, measure time to phase=rolled_back, then restore the declared good
# image. Reports per-cycle and aggregate numbers.

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

NODE="${1:-$VM_NODE_1}"
CYCLES="${2:-5}"
OFFSET="${CYCLE_OFFSET:-0}"
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"

csv="e1-rollback"
record "$csv" "cycle,broken_image,rolled_back_s,restored_s,result"
declare -a RB_TIMES=() RESTORE_TIMES=()

for i in $(seq 1 "$CYCLES"); do
  N=$((i + OFFSET))
  BROKEN_TAG="$GOOD_TAG-broken-$N"
  BROKEN_DIGEST=$(build_image "$BROKEN_TAG" "$BROKEN_TAG" Containerfile.broken "localhost:5001/os/edge-base:$GOOD_TAG")
  log "cycle $i/$CYCLES: offering $BROKEN_TAG ($BROKEN_DIGEST)"

  image_update "$NODE" "$IMAGE_REPO:$BROKEN_TAG" "$BROKEN_DIGEST" >/dev/null || fail "cycle $i: update failed"
  T0=$(date +%s)

  if RB=$(wait_for_phase "$NODE" rolled_back 1500 3); then
    log "cycle $i: rolled_back at +${RB}s"
    RB_TIMES+=("$RB")
  else
    record "$csv" "$i,$BROKEN_TAG,$RB,0,timeout"
    fail "cycle $i: no rolled_back within ${RB}s"
  fi

  image_update "$NODE" "$IMAGE_REPO:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "cycle $i: restore failed"
  if RS=$(wait_for_digest "$NODE" "$GOOD_DIGEST" 1500); then
    log "cycle $i: restored to $GOOD_TAG at +${RS}s"
    RESTORE_TIMES+=("$RS")
    record "$csv" "$i,$BROKEN_TAG,$RB,$RS,ok"
  else
    record "$csv" "$i,$BROKEN_TAG,$RB,$RS,failed-restore"
    fail "cycle $i: restore timed out"
  fi
done

avg() { local sum=0 count=$# t; for t in "$@"; do sum=$((sum + t)); done; echo $((sum / count)); }
log "E1 summary: $CYCLES cycles, rollback avg $(avg "${RB_TIMES[@]}")s (min $(printf '%s\n' "${RB_TIMES[@]}" | sort -n | head -1)s, max $(printf '%s\n' "${RB_TIMES[@]}" | sort -n | tail -1)s)"
log "E1 summary: restore avg $(avg "${RESTORE_TIMES[@]}")s"
