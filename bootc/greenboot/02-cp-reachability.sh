#!/bin/bash
# greenboot required check: an updated image must keep the node manageable.
# An image that breaks the path to the control plane (network config, NATS
# address, firewall) would otherwise pass the health gate and leave the node
# unreachable for every later fix, so on an update boot the check fails and
# greenboot rolls back.
#
# Only update boots are gated. On any other boot (power loss, plain reboot)
# the CP being down says nothing about the image: failing there made greenboot
# reboot healthy nodes until its counter ran out and left grubenv dirty for
# the next update. Those boots only log a warning.
#
# Update boot = star recorded an "applied" attempt on an earlier boot and the
# booted image is the attempted one (os_attempt.json, see star internal/bootc).
# Trade-off: a CP outage exactly during an update boot rolls back a good image
# (safe direction: the node stays on its known-good image, star parks the
# digest, the operator re-declares it).
set -o pipefail

STATE_DIR="/var/lib/c12s"
# same order as star.service: image defaults, then per-node values (wins)
ENV_FILES=("/usr/lib/c12s/node.env" "$STATE_DIR/node.env")
ATTEMPT_FILE="$STATE_DIR/os_attempt.json"

json_field() { # <file> <field>
    grep -o "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | cut -d'"' -f4
}

update_boot() {
    [ -f "$ATTEMPT_FILE" ] || return 1
    [ "$(json_field "$ATTEMPT_FILE" result)" = "applied" ] || return 1
    local attempt_boot current_boot attempt_digest booted_digest
    attempt_boot=$(json_field "$ATTEMPT_FILE" bootId)
    current_boot=$(cat /proc/sys/kernel/random/boot_id)
    [ -n "$attempt_boot" ] && [ "$attempt_boot" != "$current_boot" ] || return 1
    attempt_digest=$(json_field "$ATTEMPT_FILE" digest)
    booted_digest=$(bootc status --format=humanreadable 2>/dev/null \
        | grep 'Booted image' | grep -o 'sha256:[0-9a-f]\{64\}' | head -1)
    [ -n "$attempt_digest" ] && [ "$attempt_digest" = "$booted_digest" ]
}

if update_boot; then
    GATED=1
else
    GATED=0
fi

loaded=0
for f in "${ENV_FILES[@]}"; do
    if [ -f "$f" ]; then
        # shellcheck disable=SC1090
        source "$f"
        loaded=1
    fi
done
if [ "$loaded" = 0 ]; then
    echo "no node env file (${ENV_FILES[*]})"
    [ "$GATED" = 1 ] && exit 1
    exit 0
fi

NATS_TARGET="${NATS_ADDRESS:-$NATS_HOSTNAME:$NATS_PORT}"
if [ -z "$NATS_TARGET" ] || [ "$NATS_TARGET" = ":" ]; then
    echo "NATS address not configured in ${ENV_FILES[*]}"
    [ "$GATED" = 1 ] && exit 1
    exit 0
fi

HOST="${NATS_TARGET%%:*}"
PORT="${NATS_TARGET##*:}"

# wait for convergence: network (and NATS) may still be coming up when
# greenboot runs the checks; fail only if the CP stays unreachable
MAX_WAIT="${GREENBOOT_MAX_WAIT:-60}"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$HOST/$PORT"; then
        echo "control plane reachable at $NATS_TARGET (waited ${WAITED}s)"
        exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

if [ "$GATED" = 1 ]; then
    echo "update boot: cannot reach NATS at $NATS_TARGET within ${MAX_WAIT}s"
    exit 1
fi
echo "WARNING: cannot reach NATS at $NATS_TARGET within ${MAX_WAIT}s; not an update boot, not failing it"
exit 0
