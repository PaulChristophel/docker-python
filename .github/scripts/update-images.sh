#!/usr/bin/env bash
# Requires Bash, curl, jq, sha256sum, skopeo, and Podman on Linux.
set -euo pipefail

config=${1:-images.json}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$config" "$work/images.json"

curl --fail --silent --show-error --location --retry 3 \
  https://www.python.org/ftp/python/ -o "$work/releases.html"
releases=$(sed -nE 's/.*href="([0-9]+\.[0-9]+\.[0-9]+)\/".*/\1/p' "$work/releases.html")
test -n "$releases"

jq -e '.python | length > 0 and all(.[]; .version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$config" >/dev/null
while IFS= read -r current; do
  series=${current%.*}
  latest=$(printf '%s\n%s\n' "$releases" "$current" \
    | awk -F. -v series="$series" '$1 "." $2 == series' \
    | sort -Vu | tail -n 1)
  # Hash the same .tar.xz artifact used by the Dockerfile, even if unchanged.
  curl --fail --silent --show-error --location --retry 3 \
    "https://www.python.org/ftp/python/$latest/Python-$latest.tar.xz" \
    -o "$work/python.tar.xz"
  checksum=$(sha256sum "$work/python.tar.xz" | cut -d ' ' -f 1)
  jq --arg current "$current" --arg version "$latest" --arg sha256 "$checksum" \
    '(.python[] | select(.version == $current)) |= (. + {version: $version, sha256: $sha256})' \
    "$work/images.json" > "$work/updated.json"
  mv "$work/updated.json" "$work/images.json"
  printf 'Python %s -> %s (%s)\n' "$current" "$latest" "$checksum"
done < <(jq -r '.python[].version' "$config")

image=docker.io/opensuse/tumbleweed:latest
digest=$(skopeo inspect --override-os linux --override-arch amd64 \
  --format '{{.Digest}}' "docker://$image")
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
base="$image@$digest"
# Read the actual snapshot version from the pinned image, not today's date.
version=$(podman run --rm --pull=always --platform linux/amd64 "$base" \
  /bin/sh -c '. /etc/os-release; printf "%s" "$VERSION_ID"')
[[ "$version" =~ ^[0-9]{8}$ ]]
jq --arg base "$base" --arg version "$version" \
  '.distributions.tumbleweed |= (. + {base: $base, version: $version})' \
  "$work/images.json" > "$work/updated.json"
printf 'Tumbleweed %s (%s)\n' "$version" "$digest"

# Leave the configuration untouched if any upstream request or validation fails.
cat "$work/updated.json" > "$config"
