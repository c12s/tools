#!/usr/bin/env bash
# install-local.sh — build the c12s binaries into a local folder.
#
# It never installs anything system-wide and never edits your shell profile.
# The binaries live under one directory (default: ./bin next to this script),
# and the script writes <bin-dir>/activate.sh so you can put them on PATH for
# the current shell only:
#
#   ./install-local.sh                 # build into tools/bin
#   source tools/bin/activate.sh       # add tools/bin to PATH (bash/zsh)
#   source tools/bin/activate.fish     # same for fish
#
# Pick a different folder:
#
#   ./install-local.sh --bin-dir ~/c12s-bin
#   source ~/c12s-bin/activate.sh
#   source ~/c12s-bin/activate.fish
#
# Build only some binaries:
#
#   ./install-local.sh --only cockpit,starometry,health-check,node-metrics
#
# Usage:
#   ./install-local.sh [--bin-dir DIR] [--only NAME[,NAME]] [--all] [--clean] [--list] [--no-build]
#
# Defaults build: cockpit, star, starometry, health-check, node-metrics,
# cluster-metrics-subscriber, wormhole.  --all adds the control-plane
# binaries (lunar-gateway, magnetar, oort, apollo, pulsar, celestial,
# blackhole, discovery, monoceros, stellar, starmap).
#
# Note: the cockpit binary reads .env and token.txt from its own directory,
# so run it from the cockpit repo (or use the cockpit() function that
# activate.sh/activate.fish define):
#   (cd cockpit && ../tools/bin/cockpit ...)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
ONLY=""
ALL=0
CLEAN=0
LIST=0
NO_BUILD=0

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --all) ALL=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --list) LIST=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# name|repo|package
#   repo: directory under the workspace root
#   package: the main package to build (relative to the repo)
BUILDERS=(
  "cockpit|cockpit|."
  "star|star|./cmd"
  "starometry|starometry|./cmd"
  "health-check|protostar/health-check|."
  "node-metrics|protostar/node-metrics|."
  "cluster-metrics-subscriber|protostar/cluster-metrics-subscriber|."
  "wormhole|wormhole|."
  "lunar-gateway|lunar-gateway|."
  "magnetar|magnetar|./cmd"
  "oort|oort|./cmd"
  "apollo|apollo|."
  "pulsar|pulsar|./server"
  "celestial|celestial|."
  "blackhole|blackhole|."
  "discovery|discovery|."
  "monoceros|monoceros|./cmd"
  "stellar|stellar|."
  "starmap|starmap|./cmd"
)

DEFAULT_NAMES="cockpit,star,starometry,health-check,node-metrics,cluster-metrics-subscriber,wormhole"
if [ "$ALL" = 1 ]; then
  DEFAULT_NAMES="$(printf '%s\n' "${BUILDERS[@]}" | cut -d'|' -f1 | paste -sd, -)"
fi

if [ -n "$ONLY" ]; then
  WANT="$ONLY"
else
  WANT="$DEFAULT_NAMES"
fi

if [ "$LIST" = 1 ]; then
  printf '%s\n' "$WANT" | tr ',' '\n'
  exit 0
fi

if [ "$CLEAN" = 1 ]; then
  rm -rf "$BIN_DIR"
fi

mkdir -p "$BIN_DIR"
BIN_DIR="$(cd "$BIN_DIR" && pwd)"

log() { printf '[install-local] %s\n' "$*"; }
fail() { printf '[install-local] ERROR: %s\n' "$*" >&2; exit 1; }

command -v go >/dev/null 2>&1 || fail "go is not installed"

# Build one binary. The name in the builder table is the output name.
build_one() {
  local name="$1" repo="$2" pkg="$3"
  local src="$WORKSPACE/$repo"
  [ -d "$src" ] || { log "skip $name: $src does not exist"; return 0; }
  [ -f "$src/go.mod" ] || { log "skip $name: no go.mod in $src"; return 0; }

  log "building $name -> $BIN_DIR/$name"
  # CGO_ENABLED=0 keeps the binaries portable; -buildvcs=false keeps the
  # build working in a dirty or partial git checkout.
  ( cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -buildvcs=false -o "$BIN_DIR/$name" "$pkg" ) \
    || fail "build failed for $name"
}

IFS=',' read -r -a WANTED <<< "$WANT"
for want in "${WANTED[@]}"; do
  want="${want//[[:space:]]/}"
  [ -n "$want" ] || continue
  found=0
  for entry in "${BUILDERS[@]}"; do
    IFS='|' read -r name repo pkg <<< "$entry"
    if [ "$name" = "$want" ]; then
      if [ "$NO_BUILD" = 1 ]; then
        log "skip build $name (--no-build)"
      else
        build_one "$name" "$repo" "$pkg"
      fi
      found=1
      break
    fi
  done
  [ "$found" = 1 ] || log "skip $want: not in the build list"
done

# activate.sh: put the folder on PATH for this shell only.
# It also defines cockpit() as a wrapper that runs from the cockpit repo,
# because the binary reads .env and token.txt from its current directory.
cat > "$BIN_DIR/activate.sh" <<EOF
# Source this file to put the c12s binaries on PATH for the current shell.
#   source "$BIN_DIR/activate.sh"
# Nothing is written to ~/.bashrc or /etc/profile.
export C12S_BIN_DIR="$BIN_DIR"
export C12S_WORKSPACE="$WORKSPACE"
case ":\$PATH:" in
  *":\$C12S_BIN_DIR:"*) ;;
  *) export PATH="\$C12S_BIN_DIR:\$PATH" ;;
esac
cockpit() {
  ( cd "\$C12S_WORKSPACE/cockpit" && "\$C12S_BIN_DIR/cockpit" "\$@" )
}
EOF

# activate.fish: fish cannot source activate.sh (it uses bash `case` syntax).
cat > "$BIN_DIR/activate.fish" <<EOF
# Source this file to put the c12s binaries on PATH for the current fish shell.
#   source "$BIN_DIR/activate.fish"
# Nothing is written to ~/.config/fish/config.fish or /etc/profile.
set -gx C12S_BIN_DIR "$BIN_DIR"
set -gx C12S_WORKSPACE "$WORKSPACE"
if not contains -- \$C12S_BIN_DIR \$PATH
    set -gx PATH \$C12S_BIN_DIR \$PATH
end
function cockpit
    pushd \$C12S_WORKSPACE/cockpit >/dev/null
    \$C12S_BIN_DIR/cockpit \$argv
    popd >/dev/null
end
EOF

log "built into $BIN_DIR"
log "activate in the current shell:"
printf '  bash: source %s/activate.sh\n' "$BIN_DIR"
printf '  fish: source %s/activate.fish\n' "$BIN_DIR"
log "binaries:"
ls -1 "$BIN_DIR" | grep -v '^activate\.\(sh\|fish\)$' | sed 's/^/  /'
