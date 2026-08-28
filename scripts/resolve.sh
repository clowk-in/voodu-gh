#!/usr/bin/env bash
#
# Work out WHICH voodu CLI build this run needs, and where it will live.
# Everything downstream (the cache key, the download URL, the install dir)
# derives from the answer, so it happens once, first, in isolation.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(pick "" VOODU_INSTALL_REPO "thadeu/clowk-voodu")"
VERSION="$(pick "${INPUT_VERSION:-}" VOODU_VERSION "")"
CACHE="$(pick "" VOODU_CACHE "true")"

case "$(uname -s)" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported runner OS: $(uname -s). voodu ships linux and darwin builds." ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) die "unsupported runner arch: $(uname -m)" ;;
esac

# An unpinned version resolves the real tag BEFORE the cache step runs. That
# is the whole trick behind caching: the key names an exact release, so it is
# immutable and never needs a TTL — a new release simply produces a new key,
# and GitHub evicts what stops being touched. One cheap API call buys that.
if [ -z "$VERSION" ]; then
  note "resolving latest release from ${REPO}..."

  auth=()
  if [ -n "${INPUT_GITHUB_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}")
  fi

  VERSION="$(curl -fsSL --retry 3 --retry-delay 2 \
    "${auth[@]}" \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)" || true

  if [ -z "$VERSION" ]; then
    die "could not resolve the latest ${REPO} release. Pin one with 'version:' or VOODU_VERSION."
  fi
fi

VERSION="v${VERSION#v}"

DIR="${RUNNER_TOOL_CACHE:-${HOME}/.cache}/voodu/${VERSION}/${ARCH}"

note "voodu CLI ${VERSION} (${OS}/${ARCH})"

out version "$VERSION"
out os "$OS"
out arch "$ARCH"
out dir "$DIR"
out repo "$REPO"
out cache-key "voodu-cli-${OS}-${ARCH}-${VERSION}"

if truthy "$CACHE"; then
  out cache-enabled true
else
  out cache-enabled false
fi
