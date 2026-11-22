#!/usr/bin/env bash
# E4 — drift detection and reconciliation.
#
# Precondition: the node is healthy on the good image and the good image is
# not its immediate previous deployment. The node is then changed out of band
# (manual bootc switch to a third image + reboot). The poller must detect the
# drift (booted != desired, and booted is not the pre-switch image), switch
# back to the declared image and report healthy again.

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

NODE="${1:-$VM_NODE_1}"
NAME="${2:-$VM_NAME_1}"
# Default drift tag must be an image NOT in the node's deployment history.
# Using v3.1/v3.0 risks hitting a previous deployment and confusing the
# rollback-vs-drift inference. Build a distinct "-alt" variant instead.
DRIFT_TAG="${3:-${GOOD_TAG}-alt}"
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"
if [ "$DRIFT_TAG" = "$GOOD_TAG-alt" ]; then DRIFT_DIGEST=$(alt_image); else DRIFT_DIGEST=$(zot_digest "$DRIFT_TAG"); fi
[ -n "$DRIFT_DIGEST" ] || fail "image $DRIFT_TAG not in Zot"

CURRENT=$(node_booted_digest "$NODE")
[ "$CURRENT" = "$GOOD_DIGEST" ] || fail "precondition: node $NODE must be healthy on $GOOD_TAG (is $CURRENT)"
[ "$DRIFT_DIGEST" != "$GOOD_DIGEST" ] || fail "drift image must differ from desired"

record e4-drift "node,drift_image,detected_s,reconciled_s,result"
log "drift: out-of-band bootc switch on $NAME to $DRIFT_TAG"

T0=$(date +%s)
vm_run "$NAME" "sudo bootc switch $IMAGE_REPO:$DRIFT_TAG 2>&1 | tail -1; sudo systemctl reboot" >/dev/null 2>&1 || true

# capture the drift detection: phase leaves healthy once the poller notices
DETECTED=""
while [ $(( $(date +%s) - T0 )) -lt 300 ]; do
  phase=$(node_phase "$NODE" || true)
  if [ "$phase" != "healthy" ] && [ -n "$phase" ]; then
    DETECTED=$(( $(date +%s) - T0 ))
    log "drift detected at +${DETECTED}s (phase=$phase)"
    break
  fi
  sleep 3
done

if ELAPSED=$(wait_for_digest "$NODE" "$GOOD_DIGEST" 900); then
  log "node reconciled to $GOOD_TAG at +${ELAPSED}s (detection at ${DETECTED:-n/a}s)"
  record e4-drift "$NODE,$DRIFT_TAG,${DETECTED:-n/a},$ELAPSED,ok"
else
  record e4-drift "$NODE,$DRIFT_TAG,${DETECTED:-n/a},$ELAPSED,timeout"
  fail "drift was not reconciled within ${ELAPSED}s"
fi
