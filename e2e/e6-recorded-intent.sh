#!/usr/bin/env bash
# E6 — recorded OS intent: the desired image lives in Magnetar, not only in
# the NATS push.
#
# T1 offline catch-up: with star stopped, an update is not acknowledged but
#    recorded in Magnetar; the node does not change while offline and
#    converges after star starts (pull on the first tick).
# T2 rollback clears the intent: after `cockpit image rollback` nothing is
#    declared, the node boots its previous deployment and is not switched back.
# T3 control-plane outage: with Magnetar down an update fails before anything
#    is pushed, and nodes keep converging on their local copy (no switch).
#
# Precondition: the node runs $GOOD_TAG (an image with the pulling star).
# E6_TESTS selects tests (default "T1 T2 T3").

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

NODE="${1:-$VM_NODE_2}"
NAME="${2:-$VM_NAME_2}"
REF=$IMAGE_REPO
GOOD_DIGEST=$(zot_digest "$GOOD_TAG")
ALT_DIGEST=$(alt_image)
[ "$(node_booted_digest "$NODE")" = "$GOOD_DIGEST" ] || fail "precondition: $NODE must run $GOOD_TAG"

record e6-intent "test,node,seconds,result,detail"
TESTS="${E6_TESTS:-T1 T2 T3}"
run() { [[ " $TESTS " == *" $1 "* ]]; }

# --- T1 offline catch-up ----------------------------------------------------
if run T1; then
log "T1: stopping star on $NAME"
vm_run "$NAME" 'sudo systemctl stop star' >/dev/null 2>&1
out=$(cockpit image update --node-id "$NODE" --image-ref "$REF:$GOOD_TAG-alt" --digest "$ALT_DIGEST" 2>&1)
log "T1: $out"
echo "$out" | grep -q 'did not acknowledge' || fail "T1: update was acknowledged (is star still running?)"
[ "$(node_desired_digest "$NODE")" = "$ALT_DIGEST" ] || fail "T1: intent not recorded in Magnetar"
sleep 60
[ "$(vm_booted_digest "$NAME")" = "$GOOD_DIGEST" ] || fail "T1: node changed while its agent was offline"
log "T1: unchanged after 60 s offline, starting star"
vm_run "$NAME" 'sudo systemctl start star' >/dev/null 2>&1
if t=$(wait_for_digest "$NODE" "$ALT_DIGEST" 600); then r=ok; else r=timeout; fi
log "T1: $r after ${t}s"
record e6-intent "T1-offline-catchup,$NODE,$t,$r,$GOOD_TAG->$GOOD_TAG-alt"
[ "$r" = ok ] || fail "T1 failed"
fi

# --- T2 rollback clears the intent -------------------------------------------
if run T2; then
log "T2: rollback on $NAME"
cockpit image rollback --node-id "$NODE" >/dev/null 2>&1 || fail "T2: rollback not accepted"
[ -z "$(node_desired_digest "$NODE")" ] || fail "T2: intent not cleared"
T0=$(date +%s)
booted=""
while [ $(( $(date +%s) - T0 )) -lt 300 ]; do
  sleep 15
  booted=$(VM_RUN_TIMEOUT=30 vm_booted_digest "$NAME" || true)
  [ "$booted" = "$GOOD_DIGEST" ] && break
done
t=$(( $(date +%s) - T0 ))
[ "$booted" = "$GOOD_DIGEST" ] || fail "T2: node did not boot the previous deployment (booted $booted)"
log "T2: booted previous deployment after ${t}s, checking it stays (90 s)"
sleep 90
booted=$(vm_booted_digest "$NAME")
if [ "$booted" = "$GOOD_DIGEST" ] && [ -z "$(node_desired_digest "$NODE")" ]; then r=ok; else r=fail; fi
record e6-intent "T2-rollback-clears-intent,$NODE,$t,$r,stayed on $GOOD_TAG"
[ "$r" = ok ] || fail "T2 failed: booted $booted"
log "T2: ok, restoring $GOOD_TAG intent"
image_update "$NODE" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "T2: restore failed"
wait_for_phase "$NODE" healthy 300 >/dev/null || fail "T2: not healthy after restore"
fi

# --- T3 control-plane outage --------------------------------------------------
if run T3; then
SINCE=$(date -u '+%Y-%m-%d %H:%M:%S')   # node journals are UTC
log "T3: stopping magnetar for 90 s"
docker stop magnetar >/dev/null
out=$(cockpit image update --node-id "$NODE" --image-ref "$REF:$GOOD_TAG-alt" --digest "$ALT_DIGEST" 2>&1)
log "T3: update during outage: $out"
echo "$out" | grep -qi 'accepted\|acknowledge' && { docker start magnetar >/dev/null; fail "T3: update went through without Magnetar"; }
sleep 90
docker start magnetar >/dev/null
pushed=$(vm_run "$NAME" "sudo journalctl -u star --since '$SINCE' --no-pager | grep -c 'desired image set'" 2>/dev/null | grep -o '^[0-9]*' | tail -1)
skipped=$(vm_run "$NAME" "sudo journalctl -u star --since '$SINCE' --no-pager | grep -c 'desired image unavailable from control plane'" 2>/dev/null | grep -o '^[0-9]*' | tail -1)
sleep 60
booted=$(vm_booted_digest "$NAME")
phase=$(node_phase "$NODE")
log "T3: pushes=$pushed pull-failures-tolerated=$skipped booted=$booted phase=$phase"
if [ "${pushed:-1}" = 0 ] && [ "${skipped:-0}" -ge 1 ] && [ "$booted" = "$GOOD_DIGEST" ] && [ "$phase" = healthy ]; then r=ok; else r=fail; fi
record e6-intent "T3-cp-outage,$NODE,90,$r,pushes=$pushed tolerated=$skipped"
[ "$r" = ok ] || fail "T3 failed"
fi
log "E6 passed ($TESTS)"
