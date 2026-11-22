#!/usr/bin/env bash
# image-cache.sh — keep built OS images and disks on local disk, restore them
# into the registry (Singularity/Zot) and the artifact server without
# rebuilding: build once, `save`, and `load` into a fresh control plane.
#
#   ./image-cache.sh save [tag...]   registry + artifact server -> cache
#                                    (default: every os/edge-base tag, every qcow2)
#   ./image-cache.sh load [tag...]   cache -> registry + artifact server
#                                    (default: every cached tag; disks always)
#   ./image-cache.sh list            what the cache holds, with digests
#
# Images are copied with `skopeo copy --preserve-digests` into OCI archives,
# so a restored tag has exactly the digest it had when it was built: disks
# and nodes made from it still match (a recompressed copy would get a new
# digest and every node would "update" to the same image). skopeo runs from
# the supernova image on the compose network; nothing is installed on the
# host. Disks are plain files; the artifact server recomputes the same sha256.
#
# Environment: IMAGE_CACHE (default ~/.c12s/image-cache), REPO (os/edge-base).
set -euo pipefail

CACHE="${IMAGE_CACHE:-$HOME/.c12s/image-cache}"
REPO="${REPO:-os/edge-base}"
REGISTRY_IN_NETWORK=singularity:5000
REGISTRY_HOST=localhost:5001
ARTIFACTS=http://localhost:8081

log() { echo "[image-cache] $*"; }
fail() { echo "[image-cache] ERROR: $*" >&2; exit 1; }

skopeo() {
  docker run --rm --network tools_network --user "$(id -u):$(id -g)" \
    -v "$CACHE:/cache" --entrypoint skopeo supernova "$@"
}

digest_of() { # <tag> -> manifest digest in the registry
  curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$REGISTRY_HOST/v2/$REPO/manifests/$1" | tr -d '\r' \
    | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

archive() { echo "${REPO//\//_}_$1.tar"; }

save() {
  mkdir -p "$CACHE/disks"
  local tags=("$@")
  if [ ${#tags[@]} -eq 0 ]; then
    mapfile -t tags < <(curl -sf "http://$REGISTRY_HOST/v2/$REPO/tags/list" | jq -r '.tags[]')
  fi
  [ ${#tags[@]} -gt 0 ] || fail "no tags in $REPO"
  for tag in "${tags[@]}"; do
    log "image $REPO:$tag ($(digest_of "$tag"))"
    rm -f "$CACHE/$(archive "$tag")"
    skopeo copy --src-tls-verify=false --preserve-digests \
      "docker://$REGISTRY_IN_NETWORK/$REPO:$tag" "oci-archive:/cache/$(archive "$tag"):$REPO:$tag"
    digest_of "$tag" > "$CACHE/$(archive "$tag").digest"
  done
  for disk in $(curl -sf "$ARTIFACTS/artifacts" | jq -r '.[]'); do
    log "disk $disk"
    curl -sf -o "$CACHE/disks/$disk" "$ARTIFACTS/artifacts/$disk"
    curl -sf "$ARTIFACTS/artifacts/$disk/sha256" > "$CACHE/disks/$disk.sha256"
  done
  list
}

load() {
  [ -d "$CACHE" ] || fail "no cache at $CACHE (run save first)"
  local only=" $* "
  for f in "$CACHE"/*.tar; do
    [ -e "$f" ] || continue
    local name tag want got
    name=$(basename "$f")
    tag=${name#"${REPO//\//_}_"}; tag=${tag%.tar}
    if [ $# -gt 0 ] && [[ "$only" != *" $tag "* ]]; then
      continue
    fi
    want=$(cat "$f.digest" 2>/dev/null || true)
    log "image $REPO:$tag"
    skopeo copy --dest-tls-verify=false --preserve-digests \
      "oci-archive:/cache/$name" "docker://$REGISTRY_IN_NETWORK/$REPO:$tag"
    got=$(digest_of "$tag")
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$REPO:$tag restored as $got, saved as $want"
  done
  for f in "$CACHE"/disks/*.qcow2; do
    [ -e "$f" ] || continue
    local disk want got
    disk=$(basename "$f")
    want=$(cat "$f.sha256" 2>/dev/null || true)
    log "disk $disk"
    curl -sf -X PUT --data-binary "@$f" "$ARTIFACTS/artifacts/$disk" >/dev/null
    got=$(curl -sf "$ARTIFACTS/artifacts/$disk/sha256")
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$disk restored as $got, saved as $want"
  done
  log "restored; registry tags: $(curl -sf "http://$REGISTRY_HOST/v2/$REPO/tags/list" | jq -c .tags)"
}

list() {
  [ -d "$CACHE" ] || { log "cache $CACHE is empty"; return; }
  log "cache: $CACHE"
  for f in "$CACHE"/*.tar; do
    [ -e "$f" ] && printf '  %-44s %s  %s\n' "$(basename "$f")" "$(cat "$f.digest" 2>/dev/null)" "$(du -h "$f" | cut -f1)"
  done
  for f in "$CACHE"/disks/*.qcow2; do
    [ -e "$f" ] && printf '  %-44s %s  %s\n' "disks/$(basename "$f")" "$(cat "$f.sha256" 2>/dev/null)" "$(du -h "$f" | cut -f1)"
  done
}

case "${1:-}" in
  save) shift; save "$@" ;;
  load) shift; load "$@" ;;
  list) list ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
