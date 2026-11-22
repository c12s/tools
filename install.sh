#!/usr/bin/env bash
# install.sh — clone every repo the compose stack builds into the workspace root
# (the parent of tools/). Repos that are already there are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."

repos=(
  kuiper quasar magnetar star apollo oort gravity lunar-gateway cockpit
  heliosphere starometry protostar meridian pulsar
  supernova singularity wormhole
)
for repo in "${repos[@]}"; do
  if [ -d "$repo/.git" ]; then
    echo "[install] $repo: present, skipped"
  else
    git clone "https://github.com/c12s/$repo"
  fi
done
