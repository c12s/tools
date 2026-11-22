#!/bin/bash
# greenboot required check: star agent service must be running.
# Any required.d script exiting non-zero fails the boot; after repeated
# failed boots greenboot rolls back to the previous deployment.
#
# greenboot 0.16 runs required.d checks BEFORE boot-complete.target, i.e.
# while the system is still converging (services may not have started yet,
# network may still be down). Failing immediately on a slow boot would
# reject a healthy image, so every check must wait for convergence within
# a bounded window and only fail when the window expires.
set -o pipefail

MAX_WAIT="${GREENBOOT_MAX_WAIT:-60}"
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if systemctl is-active --quiet star.service; then
        echo "star.service is active (waited ${WAITED}s)"
        exit 0
    fi
    sleep 5
    WAITED=$((WAITED + 5))
done

echo "star.service did not become active within ${MAX_WAIT}s"
exit 1
