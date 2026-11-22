# tools — c12s local orchestration

Everything about *running* c12s on one machine lives here: the Docker
Compose control plane, start/stop scripts, the node OS image artifacts
(`bootc/`), end-to-end test scripts for OS updates (`e2e/`), and the
operator/API reference (`docs/README.md`). No service code lives in
this repository; the build contexts are the sibling repos of the workspace.

## Role in c12s

| Part | Serves |
|---|---|
| `docker-compose.yml` | the full local stack: control plane + registry/artifacts + build service + metrics |
| `start.sh` / `stop.sh` | idempotent bring-up / shutdown (schema, vault, test user, image re-seeding) |
| `image-cache.sh` | `save`/`load`/`list` built OS images (digest-preserving OCI archives via skopeo) and qcow2 disks to/from `~/.c12s/image-cache`, so a wiped or new control plane gets them back without rebuilding |
| `e2e/` | end-to-end test scripts for OS updates and VM hosts (`e2e/README.md`) |
| `bootc/` | Containerfiles + greenboot checks that go **into** the node OS image |
| `docs/README.md` | API/CLI reference |
| `vault/`, `scylla/`, `grafana/` | local infra images/config for the stack |

Compose service → source repo (build context is the workspace root):

| Container | Repo / image | Purpose |
|---|---|---|
| `magnetar`, `oort`, `kuiper`, `quasar`, `apollo`, `meridian`, `pulsar` | same-named repos | control plane services |
| `agent_queue` | `gravity` | node delivery (config/join/app-config/OS updates) |
| `lunar-gateway` | `lunar-gateway` | HTTP API on `:5555` |
| `rate_limiter_service` + `consul` | `heliosphere` | per-user/method rate limiting |
| `etcd`, `kuiper_etcd`, `quasar_etcd`, `scylla`, `vault`, `nats` | upstream images (Scylla via `scylla/Dockerfile`) | datastores/broker |
| `protostar_healthcheck`, `protostar_metrics` | `protostar` | node metric ingestion |
| `singularity` | upstream Zot image (`singularity/config/zot-config.json`) | OCI registry `:5001` |
| `singularity-files` | `singularity` | qcow2/artifact server `:8081` |
| `supernova` | `supernova` | gRPC image + qcow2 build service (`127.0.0.1:8090`); reached by the gateway as `supernova:8090` |
| `node_exporter`, `cadvisor`, `prometheus_healthcheck`, grafana | upstream | metrics |

## Running

```bash
cd tools

bash install.sh     # first time: clones missing repos
./start.sh          # control plane; idempotent, safe on old volumes
./stop.sh           # stop, keep state (volumes)
./stop.sh --clean   # also wipe volumes + dockerized node ids (fresh start)
```

`start.sh` is safe to re-run and performs, in order:

1. build (unless `--no-build`) + `docker compose up -d` (uses `docker-compose.yml`);
2. wait for Scylla and apply `scylla/create_schema_scylla.cql`;
3. wait for Apollo to initialize/unseal Vault (keys in `vault/api_key.json`);
4. ensure the test user exists and can log in —
   `e2e` / `testpass123` / org `c12s`, overridable via `C12S_USER`, `C12S_PASS`,
   `C12S_ORG`;
5. re-seed the provisioning disks (`~/.wormhole/images/edge-base-*.qcow2`,
   overridable via `QCOW2_DIR`) into the artifact server if a previous
   `stop.sh --clean` wiped them (OS image tags come back with
   `./image-cache.sh load`);
6. start Grafana (`localhost:3000`) and, if `NODES_NUM > 0`, N dockerized
   star/starometry node pairs.

`--no-build` skips the image builds and is the fast path after a host reboot;
`--build` overrides `C12S_NO_BUILD=1`. If no images exist yet, run without
`--no-build` once.

Endpoints after start: gateway `localhost:5555`, registry
`localhost:5001`, artifacts `localhost:8081`, Supernova `127.0.0.1:8090`.

`stop.sh` keeps all volumes (etcd nodes, users, vault, registry images,
artifacts) and removes dockerized nodes + Grafana; `--clean` additionally does
`docker compose down -v` and removes `nodeconfig/`. **Libvirt VMs (wormhole)
are left running** — edge nodes outlive the control plane.

### Local binaries (no system install)

`install-local.sh` builds the c12s binaries into one folder (default
`tools/bin/`) and writes `<bin-dir>/activate.sh`. Nothing is written to
`/usr/local/bin`, `/etc/profile`, or `~/.bashrc`:

```bash
./install-local.sh                 # cockpit, star, starometry, protostar, wormhole
./install-local.sh --all           # also lunar-gateway, magnetar, oort, apollo, ...
./install-local.sh --bin-dir ~/c12s-bin
source tools/bin/activate.sh       # or: source ~/c12s-bin/activate.sh
```

The activation script adds the folder to `PATH` for the current shell only.
Use `activate.sh` for bash/zsh and `activate.fish` for fish (fish cannot source
the bash `case` syntax). It also wraps `cockpit` so it runs from the cockpit
repo (the binary reads `.env` and `token.txt` from its current directory).
The built binaries are plain ELF files; `bin/` is git-ignored. The observability
binaries (`starometry`, `health-check`, `node-metrics`,
`cluster-metrics-subscriber`) are useful for running the stack outside Compose;
they still expect the environment variables described in the service READMEs.

### Lifecycle and reboot behavior

`docker compose` is a CLI, not a daemon: after `up -d` returns, Docker owns
the containers. There is deliberately **no systemd unit** for the stack;
boot recovery relies on Docker's per-container restart policy.

Every long-running service in `docker-compose.yml` uses
`restart: unless-stopped` (Grafana, started by `start.sh` outside Compose, uses
the same policy). After a host reboot or a Docker daemon restart, Docker
restarts the whole stack automatically. Consequences:

- `docker compose stop` / `docker stop` marks a container stopped;
  `unless-stopped` intentionally does **not** bring it back.
- `docker compose down` removes containers (this is what `stop.sh` does);
  `./start.sh --no-build` recreates them.
- Startup order is not guaranteed on Docker restore. `lunar-gateway` retries
  each backend until it is reachable, for up to `GATEWAY_STARTUP_TIMEOUT`
  (default `5m`), instead of panicking when a dependency is still booting.
- Vault is unsealed by Apollo on startup. If the Vault volume and
  `vault/api_key.json` do not match, automatic recovery cannot work; restore
  the matching key or use `./stop.sh --clean`.
- `./start.sh --no-build` remains the idempotent repair path: it waits for
  Scylla, re-applies the schema, checks Vault, recreates the test user, and
  re-seeds artifacts/images. Running it after a reboot is harmless and does
  not rebuild images.
- `--no-build` still fails if an image is missing. Use a normal
  `./start.sh` (or `./start.sh --build`) after changing service code.

> The Vault data volume and `vault/api_key.json` are a pair: if they do not
> match, the stack cannot unseal Vault. Restore the `api_key.json` written
> when the volume was initialized, or start over with `./stop.sh --clean`.

### End-to-end tests

`e2e/` holds scripts that test OS updates end to end (rollback, canary,
drift, offline nodes, fleet apply) on a libvirt VM host. Requirements, usage
and configuration: `e2e/README.md`.

### Dockerized "simulated" nodes

`NODES_NUM=N ./start.sh` starts N `star_i` + `starometry_i` containers
(node id state under `nodeconfig/star_i`). They are **not bootc-capable** —
they join the pool next to real nodes and exist for control-plane logic
testing only.

## Configuration

Everything is driven by `.env` (plus the Compose files). The variables that
matter most day-to-day:

| Variable | Default | Meaning |
|---|---|---|
| `NODES_NUM` | `0` | dockerized star nodes to start |
| `C12S_NO_BUILD` | `0` | `1` skips image builds in `start.sh` (same as `--no-build`; `--build` overrides) |
| `SINGULARITY_PORT` / `SINGULARITY_HOST_PORT` | `5000` / `5001` | registry inside/outside compose (nodes use the host's address, see `bootc/node.env`) |
| `SINGULARITY_FILES_PORT` / `..._HOST_PORT` | `8080` / `8081` | artifact server inside/outside |
| `SUPERNOVA_PORT` / `SUPERNOVA_HOST_PORT` | `8090` | build service (bound to `127.0.0.1` only) |
| `SUPERNOVA_ENGINE_REGISTRY` | `localhost:5001` | registry address the push reaches (compose: `singularity:5000`) |
| `NATS_ADDRESS` | `nats:4222` | broker address given to in-network services |
| `SECRET_KEY` | `secret-key` | shared JWT signing key (development value — change it) |
| `BIND_PORT` | `7946` | Serf/gossip port baked into images and docker nodes |
| `NODE_STALE_AFTER` / `NODE_OFFLINE_AFTER` | `90s` / `5m` | node liveness thresholds (Magnetar derives `online`/`stale`/`offline` from the last heartbeat) |
| `NODE_GC_ENABLED` | `true` | Magnetar's stale-record GC |
| `NODE_GC_INTERVAL` / `NODE_GC_POOL_AFTER` | `10m` / `24h` | GC cadence; unclaimed (pool) records without a heartbeat for this long are deleted. Org-owned nodes are never GC'd — delete them explicitly with `cockpit delete node` |
| `GRAFANA`/metrics ports | see file | protostar/starometry/cadvisor/node_exporter wiring |

`NODES_NUM`, `C12S_USER/PASS/ORG`, `QCOW2_DIR`, `METRICS_*` are read by
`start.sh` at run time (environment overrides `.env`).

Nodes heartbeat every 30 s (`HEARTBEAT_INTERVAL` in `node.env`; the value is
baked into the node image's environment and read by star). A node that
heartbeats successfully shows up as `online` in `cockpit list nodes`; a node
whose record Magnetar lost (e.g. `stop.sh --clean`) learns this from the
heartbeat reply and re-registers with the same id.
