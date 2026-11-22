# End-to-end OS-update tests

Bash scripts that drive the real path — cockpit → control plane → node →
reboot → greenboot — on bootc VMs and check the outcome from the node state
Magnetar stores.

## Requirements

- The compose stack running (`../start.sh`) and `cockpit` built.
- A libvirt VM host enrolled as a c12s node with `run_vms` (e.g. wormhole
  `config.libvirt.yaml`), reachable over SSH with a key, passwordless `sudo`,
  and `python3` on it.
- On this machine: `docker`, `protoc`, `curl`, `python3`, `ssh`.

## Run

```bash
./setup-fleet.sh 2            # build the test image, claim the VM host,
                              # create 2 VMs, wait until they are healthy
./e1-rollback-reliability.sh  # then any test, in any order
```

`setup-fleet.sh` writes the node ids to `results/fleet.env`; the tests read
them from there. Results (CSV) go to `results/`, which git ignores.

| Test | Checks |
|---|---|
| `e1-rollback-reliability.sh [node] [cycles]` | a broken image is rolled back by greenboot, every cycle |
| `e2-convergence.sh [tag]` | time until all nodes run a newly declared image |
| `e3-canary-gate.sh [canary] [target]` | `image rollout` stops on a failing canary, proceeds on a healthy one |
| `e4-drift-detection.sh [node] [name] [tag]` | a manual `bootc switch` is reverted to the declared image |
| `e5-airgapped.sh [node] [name] [tag]` | an update works with only the control-plane host reachable |
| `e6-recorded-intent.sh [node] [name]` | offline catch-up, rollback, Magnetar outage (`E6_TESTS`) |
| `e7-cp-unreachable-boot.sh [node] [name]` | a plain reboot without the CP passes, an update boot rolls back (`E7_TESTS`) |
| `e8-declarative-apply.sh [canary] [target]` | `image apply`: dry run, idempotency, canary first |

`e5` and `e7` add temporary nft rules on the VM host and remove them on exit.

## Configuration

Environment variables, defaults in `common.sh`:

| Variable | Default | Meaning |
|---|---|---|
| `HOST_VM_IP` | `192.168.122.61` | VM host address (SSH as `c12s@`) |
| `CP_HOST` | `192.168.122.1` | control-plane host as the nodes reach it |
| `REGISTRY` / `DISK_REGISTRY` | `$CP_HOST:5001` / `http://$CP_HOST:8081` | node-visible image registry and disk server |
| `GOOD_TAG` | `v4.1` | image tag the fleet runs; broken/alt tags are derived from it |
| `FLEET_QCOW2` | `edge-base-v4.0.qcow2` | disk the test VMs are created from |
| `GATEWAY` | `http://localhost:5555` | API gateway |
| `C12S_USER` / `C12S_PASS` / `C12S_ORG` | `e2e` / `testpass123` / `c12s` | the stack's test user |
| `COCKPIT_BIN` | `~/.cache/c12s/cockpit` | cockpit binary |
