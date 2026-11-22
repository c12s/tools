#!/usr/bin/env bash
# E7 — health gate with the control plane unreachable.
#
# The node loses its path to NATS (firewall rule on the libvirt host), the
# rest of the stack keeps running.
# T1 plain reboot: one boot, greenboot passes with a warning (not an update
#    boot), grubenv stays clean, star keeps running without restarts.
# T2 update boot: the update is delivered, then the CP becomes unreachable.
#    greenboot rejects the new image (update boots must reach the CP), falls
#    back, the fallback boot passes; the node reports rolled_back once the CP
#    is reachable again.
#
# Precondition: the node runs $GOOD_TAG (with the update-boot-only CP check
# and reconnecting NATS clients). E7_TESTS selects tests (default "T1 T2").

set -uo pipefail
source "$(dirname "$0")/common.sh"
fleet_load
ensure_cockpit
login

NODE="${1:-$VM_NODE_1}"
NAME="${2:-$VM_NAME_1}"
REF=$IMAGE_REPO
GOOD_DIGEST=$(zot_digest "$GOOD_TAG")
ALT_DIGEST=$(alt_image)
[ "$(node_booted_digest "$NODE")" = "$GOOD_DIGEST" ] || fail "precondition: $NODE must run $GOOD_TAG"
TESTS="${E7_TESTS:-T1 T2}"
run() { [[ " $TESTS " == *" $1 "* ]]; }

IP=$(vm_run "$NAME" 'hostname -I' 2>/dev/null | grep -oE '192\.168\.123\.[0-9]+' | head -1)
[ -n "$IP" ] || fail "no address for $NAME"

cp_block() {
  $HOST_SSH "sudo nft insert rule ip libvirt_network guest_output iif \"virbr-c12s\" ip saddr $IP ip daddr $CP_HOST tcp dport 4222 counter drop comment \"c12s-cpdown\"" \
    || fail "could not block the CP for $NAME"
  log "NATS blocked for $NAME ($IP)"
}
cp_unblock() {
  $HOST_SSH 'for h in $(sudo nft -a list chain ip libvirt_network guest_output | awk "/c12s-cpdown/{print \$NF}"); do sudo nft delete rule ip libvirt_network guest_output handle $h; done' >/dev/null 2>&1 || true
}
trap cp_unblock EXIT

vm_q() { VM_RUN_TIMEOUT=30 vm_run "$NAME" "$1" 2>/dev/null | tr -d '\r' | grep -E "$2" | tail -1; }
boot_id() { vm_q 'cat /proc/sys/kernel/random/boot_id' '^[0-9a-f-]{36}$'; }
boot_count() { vm_q 'echo BOOTS=$(journalctl --list-boots --no-pager -q | wc -l)' '^BOOTS=' | cut -d= -f2; }
gb_state() { vm_q 'echo GB=$(systemctl show -p ActiveState --value greenboot-healthcheck)/$(systemctl show -p Result --value greenboot-healthcheck)' '^GB=' | cut -d= -f2; }

wait_new_boot() { # <old boot id> <timeout> -> waits for another boot whose health check finished
  local old=$1 timeout=$2 start id gb
  start=$(date +%s)
  while [ $(( $(date +%s) - start )) -lt "$timeout" ]; do
    sleep 15
    id=$(boot_id || true)
    [ -n "$id" ] && [ "$id" != "$old" ] || continue
    gb=$(gb_state || true)
    case "$gb" in activating*|"") continue ;; esac
    echo "$id"
    return 0
  done
  return 1
}

record e7-cp-unreachable "test,node,seconds,boots,result,detail"

# --- T1 plain reboot without CP ---------------------------------------------
if run T1; then
B0=$(boot_count); OLD=$(boot_id)
cp_block
T0=$(date +%s)
vm_run "$NAME" 'sudo systemctl reboot' >/dev/null 2>&1 || true
wait_new_boot "$OLD" 400 >/dev/null || fail "T1: $NAME did not come back"
sleep 60   # a failed gate would reboot right after the check
B1=$(boot_count)
gb=$(gb_state)
warned=$(vm_q 'journalctl -b -u greenboot-healthcheck --no-pager | grep -c "not an update boot"' '^[0-9]+$')
grubenv=$(vm_q 'echo ENV=$(sudo grub2-editenv list | tr "\n" " ")' '^ENV=')
restarts=$(vm_q 'echo NR=$(systemctl show -p NRestarts --value star)/$(systemctl is-active star)' '^NR=' | cut -d= -f2)
t=$(( $(date +%s) - T0 )); boots=$(( B1 - B0 ))
log "T1: boots=$boots greenboot=$gb warned=$warned $grubenv star=$restarts"
if [ "$boots" = 1 ] && [ "$gb" = active/success ] && [ "${warned:-0}" -ge 1 ] \
   && [[ "$grubenv" == *boot_success=1* ]] && [[ "$grubenv" != *boot_counter* ]] && [ "$restarts" = 0/active ]; then r=ok; else r=fail; fi
cp_unblock
record e7-cp-unreachable "T1-reboot-cp-down,$NODE,$t,$boots,$r,greenboot=$gb star=$restarts"
[ "$r" = ok ] || fail "T1 failed"
wait_for_phase "$NODE" healthy 180 >/dev/null || fail "T1: not healthy after CP came back"
fi

# --- T2 update boot without CP ------------------------------------------------
if run T2; then
B0=$(boot_count); OLD=$(boot_id)
image_update "$NODE" "$REF:$GOOD_TAG-alt" "$ALT_DIGEST" >/dev/null || fail "T2: update not delivered"
cp_block
T0=$(date +%s)
# alt boot (gate fails) -> alt boot (fails) -> fallback to the good image
booted=""
while [ $(( $(date +%s) - T0 )) -lt 1200 ]; do
  sleep 20
  booted=$(VM_RUN_TIMEOUT=30 vm_booted_digest "$NAME" || true)
  if [ "$booted" = "$GOOD_DIGEST" ] && [ "$(boot_id || true)" != "$OLD" ]; then
    case "$(gb_state || true)" in active/success) break ;; esac
  fi
done
t=$(( $(date +%s) - T0 ))
sleep 60
B1=$(boot_count); boots=$(( B1 - B0 ))
booted=$(vm_booted_digest "$NAME")
gb=$(gb_state)
gated=$(vm_q 'journalctl -b -1 -u greenboot-healthcheck --no-pager | grep -c "update boot: cannot reach NATS"' '^[0-9]+$')
grubenv=$(vm_q 'echo ENV=$(sudo grub2-editenv list | tr "\n" " ")' '^ENV=')
log "T2: after ${t}s boots=$boots booted=$booted greenboot=$gb gated-previous-boot=$gated $grubenv"
cp_unblock
phase_t=$(wait_for_phase "$NODE" rolled_back 300) && phase=rolled_back || phase=$(node_phase "$NODE")
log "T2: phase after CP is back: $phase"
if [ "$booted" = "$GOOD_DIGEST" ] && [ "$gb" = active/success ] && [ "${gated:-0}" -ge 1 ] \
   && [[ "$grubenv" != *boot_counter* ]] && [ "$phase" = rolled_back ]; then r=ok; else r=fail; fi
record e7-cp-unreachable "T2-update-boot-cp-down,$NODE,$t,$boots,$r,fell back to $GOOD_TAG"
image_update "$NODE" "$REF:$GOOD_TAG" "$GOOD_DIGEST" >/dev/null || log "T2: restore of $GOOD_TAG intent failed"
[ "$r" = ok ] || fail "T2 failed"
fi
log "E7 passed ($TESTS)"
