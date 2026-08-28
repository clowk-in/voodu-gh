#!/usr/bin/env bash
#
# Prepare the SSH side: private key on disk, host key pinned, per-host
# client config. Everything lands under RUNNER_TEMP, which the runner wipes
# between jobs — composite actions cannot register a `post:` cleanup step,
# so the temp dir is what keeps the key from outliving the job.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST="$(pick "${INPUT_HOST:-}" VOODU_HOST "")"
USER_INPUT="$(pick "${INPUT_USER:-}" VOODU_USER "")"
KEY="$(pick "${INPUT_SSH_KEY:-}" VOODU_SSH_KEY "")"
KNOWN="$(pick "${INPUT_KNOWN_HOSTS:-}" VOODU_KNOWN_HOSTS "")"
PORT="$(pick "${INPUT_PORT:-}" VOODU_PORT "22")"

[ -n "$HOST" ] || die "no host. Pass 'host:' on the step, or set VOODU_HOST once in the workflow env."
[ -n "$KEY" ]  || die "no ssh key. Pass 'ssh-key:', or set VOODU_SSH_KEY once in the workflow env."

# Mask the raw value before anything can echo it back, including the errors
# below. GitHub masks values it knows are secrets; one supplied through a
# plain env var is not one.
echo "::add-mask::${HOST}"

# voodu wants a 'user@host' target. Accepting the user separately means only
# the address has to be a secret, and 'user: ubuntu' stays readable in the
# workflow. A host that already carries a user wins, so the two forms never
# fight over the same value.
case "$HOST" in
  *@*)
    if [ -n "$USER_INPUT" ] && [ "${HOST%%@*}" != "$USER_INPUT" ]; then
      warn "host already names user '${HOST%%@*}', so the 'user' input ('${USER_INPUT}') is ignored."
    fi
    ;;
  *)
    [ -n "$USER_INPUT" ] || die "host '${HOST}' has no user. Write it as user@hostname, or pass 'user:' (or VOODU_USER) alongside."

    HOST="${USER_INPUT}@${HOST}"
    ;;
esac

echo "::add-mask::${HOST}"
echo "::add-mask::${HOST#*@}"

# voodu's remote parser treats everything after ':' as a path to a key, so a
# 'user@host:2222' target is rejected downstream with a confusing message.
# Catch it here and point at the input that actually exists.
case "${HOST#*@}" in
  *:*) die "host must not carry a port. Drop the ':<port>' suffix and pass 'port:' (or VOODU_PORT) instead." ;;
esac

HOSTNAME_ONLY="${HOST#*@}"
SLUG="$(printf '%s' "$HOSTNAME_ONLY" | tr -c 'a-zA-Z0-9' '_')"

WORK="${RUNNER_TEMP:-$(mktemp -d)}/voodu"
mkdir -p "$WORK"
chmod 700 "$WORK"

IDENTITY="${WORK}/${SLUG}.key"
KNOWN_FILE="${WORK}/${SLUG}.known_hosts"

# Two things break pasted keys more than anything else: a stripped trailing
# newline and CRLF line endings. Normalise both rather than making the user
# debug 'invalid format' against an opaque runner.
printf '%s\n' "$KEY" | tr -d '\r' | sed '/^$/d' > "$IDENTITY"
printf '\n' >> "$IDENTITY"
chmod 600 "$IDENTITY"

if ! ssh-keygen -y -f "$IDENTITY" >/dev/null 2>&1; then
  die "the ssh key could not be read. Copy the PRIVATE key whole, including the BEGIN/END lines, into the secret."
fi

STRICT="yes"

if [ -n "$KNOWN" ]; then
  printf '%s\n' "$KNOWN" | tr -d '\r' > "$KNOWN_FILE"
else
  : > "$KNOWN_FILE"
  STRICT="accept-new"

  warn "no known-hosts given, so this run trusts whatever host key answers. On an ephemeral runner that accepts ANY key — a man in the middle would go unnoticed. Pin it with: ssh-keyscan -p ${PORT} <host>"
fi

chmod 600 "$KNOWN_FILE"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

CONFIG="${HOME}/.ssh/config"
touch "$CONFIG"
chmod 600 "$CONFIG"

# Rewrite this host's block instead of appending to it, so a second `uses:`
# targeting the same host updates in place rather than stacking a duplicate
# Host stanza (ssh honours the FIRST match, so a stale block would win).
BEGIN="# >>> voodu-gh ${HOSTNAME_ONLY} >>>"
END="# <<< voodu-gh ${HOSTNAME_ONLY} <<<"

if grep -qF "$BEGIN" "$CONFIG" 2>/dev/null; then
  tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" '
    $0 == b { skip = 1 }
    skip != 1 { print }
    $0 == e { skip = 0 }
  ' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  chmod 600 "$CONFIG"
fi

{
  echo "$BEGIN"
  echo "Host ${HOSTNAME_ONLY}"
  echo "  IdentityFile ${IDENTITY}"
  echo "  IdentitiesOnly yes"
  echo "  Port ${PORT}"
  echo "  UserKnownHostsFile ${KNOWN_FILE}"
  echo "  StrictHostKeyChecking ${STRICT}"
  echo "  BatchMode yes"
  echo "$END"
} >> "$CONFIG"

note "ssh ready (port ${PORT}, host key checking: ${STRICT})"

out identity "$IDENTITY"
out host "$HOST"
