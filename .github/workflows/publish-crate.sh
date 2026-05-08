#!/usr/bin/env bash
# Publish a workspace crate to crates.io, treating "already exists on
# crates.io index" as a successful skip. The cheap pre-check
# (`/api/v1/crates/{name}/{version}`) races API propagation: a version
# can be in the registry index (which `cargo publish` consults) before
# the public API endpoint returns 200 for it. Trusting cargo's own
# error message is authoritative.

set -euo pipefail

CRATE="${1:?crate name required}"

V=$(cargo metadata --format-version=1 --no-deps \
    | jq -r --arg c "$CRATE" '.packages[] | select(.name==$c) | .version')

# Cheap path: API says it's there → skip without running cargo at all.
if curl -sfL -o /dev/null "https://crates.io/api/v1/crates/${CRATE}/${V}"; then
  echo "${CRATE} ${V} already on crates.io, skipping"
  exit 0
fi

# Slow path: try to publish. If cargo says "already exists on crates.io
# index", the version raced the API check — treat as success.
set +e
output=$(cargo publish -p "$CRATE" 2>&1)
ec=$?
set -e
echo "$output"

if [ "$ec" -eq 0 ]; then
  exit 0
fi

if grep -q 'already exists on crates.io index' <<<"$output"; then
  echo "${CRATE} ${V} already in index, treating as already-published"
  exit 0
fi

exit "$ec"
