#!/usr/bin/env bash
#
# Put the voodu CLI on PATH. Downloads the release archive only when it is
# not already sitting in VD_DIR — which covers both a cache hit and a second
# `uses:` of this action inside the same job.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(pick "" VOODU_INSTALL_REPO "thadeu/clowk-voodu")"

: "${VD_VERSION:?internal error: VD_VERSION unset}"
: "${VD_DIR:?internal error: VD_DIR unset}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [ -x "${VD_DIR}/voodu" ]; then
  note "voodu ${VD_VERSION} already present, skipping download"
else
  num="${VD_VERSION#v}"
  archive="voodu_${num}_${VD_OS}_${VD_ARCH}.tar.gz"
  base="https://github.com/${REPO}/releases/download/${VD_VERSION}"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  note "downloading ${archive}"

  if ! curl -fsSL --retry 3 --retry-delay 2 "${base}/${archive}" -o "${tmp}/${archive}"; then
    die "download failed: ${base}/${archive} — check that '${VD_VERSION}' is a real release for ${VD_OS}/${VD_ARCH}."
  fi

  # The release ships a checksums.txt. Verifying it is cheap and it is the
  # only thing standing between a compromised download and a shell on the
  # deploy target, so a missing checksums file is a hard failure, not a
  # shrug — a real release always has one.
  if ! curl -fsSL --retry 3 --retry-delay 2 "${base}/checksums.txt" -o "${tmp}/checksums.txt"; then
    die "could not fetch checksums.txt for ${VD_VERSION}; refusing to install an unverified binary."
  fi

  expected="$(awk -v f="$archive" '$2 == f || $2 == "*"f {print $1}' "${tmp}/checksums.txt" | head -1)"

  if [ -z "$expected" ]; then
    die "checksums.txt for ${VD_VERSION} has no entry for ${archive}; refusing to install."
  fi

  actual="$(sha256_of "${tmp}/${archive}")"

  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch for ${archive}: expected ${expected}, got ${actual}."
  fi

  note "checksum verified"

  tar -xzf "${tmp}/${archive}" -C "$tmp"

  if [ ! -x "${tmp}/voodu" ]; then
    die "${archive} did not contain an executable named 'voodu'."
  fi

  mkdir -p "$VD_DIR"
  install -m 0755 "${tmp}/voodu" "${VD_DIR}/voodu"
fi

# `vd` is the shorthand every voodu doc uses; keep it available here too.
ln -sf "${VD_DIR}/voodu" "${VD_DIR}/vd"

case ":${PATH}:" in
  *":${VD_DIR}:"*) ;;
  *) echo "$VD_DIR" >> "$GITHUB_PATH" ;;
esac

export PATH="${VD_DIR}:${PATH}"

note "$("${VD_DIR}/voodu" version 2>/dev/null || echo "voodu ${VD_VERSION}")"
