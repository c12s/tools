#!/usr/bin/env bash
# E8 — declarative apply (HostImageSpec fleet spec).
#
# Drives `cockpit image apply --spec`: the spec names nodes by id and says
# which image each runs; apply updates only the listed nodes, canary first.
#
#   T1 dry-run: the plan is printed and nothing is changed.
#   T2 idempotency: the fleet already runs the pinned digest, so apply finds
#      nothing to do; --force re-sends the update to prove the override.
#   T3 tag spec: a new tag is built, the spec names it by tag only, apply
#      resolves the tag to its digest and rolls it out behind the canary
#      gate. The fleet is restored afterwards.
#
# Precondition: setup-fleet.sh has run; the fleet is healthy on $GOOD_TAG.
# Usage: e8-declarative-apply.sh [canary] [target]

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

CANARY="${1:-$VM_NODE_1}"
TARGET="${2:-$VM_NODE_2}"
REF=$IMAGE_REPO
GOOD_DIGEST="${GOOD_DIGEST:-$(zot_digest "$GOOD_TAG")}"
[ -n "$GOOD_DIGEST" ] || fail "no digest for $GOOD_TAG"
[ "$(node_booted_digest "$CANARY")" = "$GOOD_DIGEST" ] || fail "precondition: $CANARY must run $GOOD_TAG"
[ "$(node_booted_digest "$TARGET")" = "$GOOD_DIGEST" ] || fail "precondition: $TARGET must run $GOOD_TAG"

record e8-apply "test,node,seconds,result,detail"
TMP="$TMP_DIR/e8"
mkdir -p "$TMP"

# spec <file> <ref> [digest]: both nodes on one image, canary first
spec() {
  local file=$1 ref=$2 digest=${3:-} pin=""
  [ -n "$digest" ] && pin="
      digest: $digest"
  cat > "$file" <<EOF
apiVersion: c12s/os.v1
kind: HostImageSpec
metadata:
  org: $C12S_ORG
spec:
  images:
    edge-base:
      ref: $ref$pin
  nodes:
    - {id: $CANARY, name: canary, image: edge-base, canary: true}
    - {id: $TARGET, name: target, image: edge-base}
  rollout:
    soak: 2m
    timeout: 15m
EOF
}

# --- T1: dry-run prints the plan -------------------------------------------
spec "$TMP/pinned.yaml" "$REF:$GOOD_TAG" "$GOOD_DIGEST"
out=$(image_apply "$TMP/pinned.yaml" --dry-run --force 2>&1) || fail "T1 dry-run failed"
echo "$out" | grep -q 'Dry run: nothing was changed' || fail "T1 dry-run did not print the plan"
echo "$out" | grep -q '\[canary\]' || fail "T1 plan has no canary"
log "T1 dry-run ok"
record e8-apply "T1-dry-run,$CANARY,0,ok,plan printed"

# --- T2: apply is idempotent; --force overrides -----------------------------
out=$(image_apply "$TMP/pinned.yaml" 2>&1) || fail "T2 apply failed"
echo "$out" | grep -q 'Up to date' || fail "T2 apply did not find the fleet up to date"
log "T2 idempotent apply ok"
record e8-apply "T2-idempotent,$CANARY,0,ok,up to date"

T0=$(date +%s)
out=$(image_apply "$TMP/pinned.yaml" --force 2>&1) || { echo "$out" >&2; fail "T2 force apply failed"; }
echo "$out" | grep -q 'sending' || fail "T2 force apply did not send an update"
t=$(( $(date +%s) - T0 ))
log "T2 force apply ok in ${t}s"
record e8-apply "T2-force,$CANARY,$t,ok,re-sent"

# --- T3: new tag, referenced by tag only, rolled out ------------------------
TAG="$GOOD_TAG-apply"
NEW_DIGEST=$(build_image "$TAG" "$TAG") || fail "T3 build of $TAG failed"
spec "$TMP/tag.yaml" "$REF:$TAG"
T0=$(date +%s)
if ! out=$(image_apply "$TMP/tag.yaml" 2>&1); then
  echo "$out" >&2
  fail "T3 apply failed"
fi
t=$(( $(date +%s) - T0 ))
echo "$out"
echo "$out" | grep -q "${NEW_DIGEST:7:12}" || fail "T3 plan did not resolve $TAG to $NEW_DIGEST"
[ "$(node_booted_digest "$TARGET")" = "$NEW_DIGEST" ] || fail "T3 target not on $TAG"
log "T3 applied $TAG (resolved from its tag) in ${t}s"
record e8-apply "T3-tag-apply,$CANARY,$t,ok,$NEW_DIGEST"

# --- restore the fleet to the good image ------------------------------------
image_update "$CANARY" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "T3 restore canary failed"
wait_for_digest "$CANARY" "$GOOD_DIGEST" 600 >/dev/null || fail "T3 canary not healthy on $GOOD_TAG"
image_update "$TARGET" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || fail "T3 restore target failed"
wait_for_digest "$TARGET" "$GOOD_DIGEST" 600 >/dev/null || fail "T3 target not healthy on $GOOD_TAG"
log "T3 restored to $GOOD_TAG"
log "E8 passed"
