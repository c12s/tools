#!/usr/bin/env bash
# setup-fleet.sh [vm-count] — precondition for the E1–E8 tests.
#
# Builds the "good" experiment image (edge-base $GOOD_TAG), declares N bootc
# VMs on the libvirt VM host, waits for them to enroll and become healthy, grants os.update for the experiment user, and
# saves the node map to results/fleet.env.

set -uo pipefail
source "$(dirname "$0")/common.sh"

N=${1:-2}

ensure_cockpit
login
GOOD_DIGEST=$(ensure_good_image) || fail "good image build failed"
log "good image $GOOD_TAG=$GOOD_DIGEST"

fleet_claim
fleet_set "$N"
fleet_wait "$N"
fleet_claim
fleet_ready "$N"
fleet_pin "$N" "$GOOD_DIGEST"
fleet_save "$N"
echo "GOOD_DIGEST=$GOOD_DIGEST" >> "$RESULTS_DIR/fleet.env"
echo "FLEET_GOOD_TAG=$GOOD_TAG" >> "$RESULTS_DIR/fleet.env"

log "fleet up: $N node(s) healthy on $GOOD_TAG; results in $RESULTS_DIR"
