#!/usr/bin/env bash
#
# Spread a directory tree over numbered sub-trees of at most LIMIT bytes each,
# so that one COPY per sub-tree gives a Docker image whose every layer fits
# under the Develocity Edge's maximum artifact size.
#
# Artifact Cache stores each Docker image layer as ONE cache entry, and an
# image with a layer above the Edge limit (100 MiB by default) is never
# restored. A Gradle user home baked with a single COPY is one multi-GB layer,
# so it would be skipped silently — this is what avoids that.
#
#   split-into-layers.sh <src> <dst> <limit-bytes>
#
# Files are taken in path order, so a dependency's files stay together and a
# changed dependency only changes the layers it lands in. A single file above
# the limit is an error: no layering can make it fit.
set -euo pipefail

SRC="${1:?usage: split-into-layers.sh <src> <dst> <limit-bytes>}"
DST="${2:?}"
LIMIT="${3:?}"

mkdir -p "$DST/.lists"

# %s is the file size (link length for a symlink); tar adds a 512-byte header
# per entry and pads to 512, so budget that too. Empty directories go to layer 000.
( cd "$SRC" && find . -mindepth 1 \( -type f -o -type l \) -printf '%s\t%p\n' | LC_ALL=C sort -t "$(printf '\t')" -k2 ) \
  | awk -F '\t' -v limit="$LIMIT" -v lists="$DST/.lists" '
      {
        size = $1 + 1024
        if (size > limit) { printf "ERROR: %s is %d bytes, above the %d-byte layer limit\n", $2, $1, limit > "/dev/stderr"; bad = 1; next }
        if (used > 0 && used + size > limit) { n++; used = 0 }
        used += size
        print $2 > sprintf("%s/%03d", lists, n)
      }
      END { if (bad) exit 1 }'

( cd "$SRC" && find . -mindepth 1 -type d -empty ) >> "$DST/.lists/000"

for list in "$DST"/.lists/*; do
  layer="$DST/$(basename "$list")"
  mkdir -p "$layer"
  tar -C "$SRC" --no-recursion -cf - -T "$list" | tar -C "$layer" -xpf -
done
rm -rf "$DST/.lists"

echo "layers (limit $((LIMIT / 1024 / 1024)) MiB):"
du -sh "$DST"/* | sed 's/^/   /'
