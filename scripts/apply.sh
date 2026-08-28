#!/usr/bin/env bash
#
# Run the deploy. voodu resolves its SSH target through a git remote
# (internal/remote: `git remote get-url <name>`), so the target is written
# into the checkout as a remote before the CLI is called.
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFESTS="$(pick "${INPUT_MANIFESTS:-}" VOODU_MANIFESTS "")"
WORKDIR="$(pick "${INPUT_WORKDIR:-}" VOODU_WORKDIR ".")"
REMOTE="$(pick "${INPUT_REMOTE_NAME:-}" VOODU_REMOTE_NAME "voodu")"
DRY_RUN="$(pick "${INPUT_DRY_RUN:-}" VOODU_DRY_RUN "false")"

[ -n "$MANIFESTS" ] || die "no manifests. Pass 'manifests:' on the step, or set VOODU_MANIFESTS in the workflow env."
[ -n "${VD_HOST:-}" ] || die "internal error: host did not reach the apply step."

cd "$WORKDIR" || die "working-directory '${WORKDIR}' does not exist."

git config --global --add safe.directory "$PWD" >/dev/null 2>&1 || true

# The remote is only a key/value store for the SSH target. When the workspace
# is not a repo (no actions/checkout), an empty one is enough to hold it.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  warn "'${WORKDIR}' is not a git repository — creating an empty one to carry the voodu remote. Add actions/checkout if the manifests are meant to come from the repo."

  git init -q .
fi

git remote remove "$REMOTE" >/dev/null 2>&1 || true
git remote add "$REMOTE" "$VD_HOST"

# Build the -f list. `-f` is repeatable (StringArrayVarP), so every manifest
# goes into ONE invocation: one plan, one apply, one set of SSH round-trips,
# and resources across files are reconciled together rather than in
# independent passes that cannot see each other.
files=()

while IFS= read -r line; do
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"

  [ -n "$line" ] || continue

  case "$line" in \#*) continue ;; esac

  # Only expand entries that actually look like globs. Plain paths pass
  # through untouched so voodu can apply its own resolution (optional
  # extension, .voodu/ lookup, directories walked recursively).
  case "$line" in
    *'*'*|*'?'*|*'['*)
      # compgen expands the pattern and prints one path per line, so a match
      # containing a space stays one entry — plain array assignment would
      # word-split it into two broken paths. Read it with a loop rather than
      # mapfile, which macOS's bash 3.2 does not have.
      matches=()

      while IFS= read -r match; do
        [ -n "$match" ] || continue

        matches+=("$match")
      done < <(compgen -G "$line" || true)

      if [ ${#matches[@]} -eq 0 ]; then
        die "manifest pattern '${line}' matched no files."
      fi

      for m in "${matches[@]}"; do
        files+=("$m")
      done
      ;;
    *)
      files+=("$line")
      ;;
  esac
done <<< "$(printf '%s' "$MANIFESTS" | tr ',' '\n')"

[ ${#files[@]} -gt 0 ] || die "manifests resolved to an empty list."

args=()

for f in "${files[@]}"; do
  args+=(-f "$f")
done

if truthy "$DRY_RUN"; then
  verb="diff"
  note "planning ${#files[@]} manifest(s) — dry run, nothing is applied"
else
  verb="apply"
  args+=(-y)

  note "applying ${#files[@]} manifest(s)"
fi

for f in "${files[@]}"; do
  printf '       %s\n' "$f"
done

# The confirmation prompt has no terminal to read from here, so approval is
# always implied. It is set twice on purpose: the flag covers the CLI, the
# env var covers anything the CLI re-invokes.
export VOODU_AUTO_APPROVE=1

set +e
voodu "$verb" "${args[@]}" --remote "$REMOTE"
code=$?
set -e

{
  echo "### voodu ${verb}"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| CLI | \`${VD_VERSION:-unknown}\` |"
  echo "| Manifests | ${#files[@]} |"
  echo "| Result | $([ $code -eq 0 ] && echo 'succeeded ✅' || echo "failed ❌ (exit ${code})") |"
  echo
  for f in "${files[@]}"; do
    echo "- \`${f}\`"
  done
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ $code -ne 0 ]; then
  die "voodu ${verb} failed with exit code ${code}. The full server output is in this step's log above."
fi

note "done"
