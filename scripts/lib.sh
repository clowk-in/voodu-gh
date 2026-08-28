# Shared helpers. Sourced, never executed.

# pick <explicit> <ambient-env-name> [default]
#
# The `with:` value wins; otherwise fall back to the shared environment
# variable, then to the default. This is what lets a workflow declare
# VOODU_HOST / VOODU_SSH_KEY once at the top and keep every `uses:` block
# down to the one input that actually differs.
pick() {
  local explicit="${1:-}" ambient_name="${2:-}" fallback="${3:-}"

  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"

    return
  fi

  local ambient="${!ambient_name:-}"

  if [ -n "$ambient" ]; then
    printf '%s' "$ambient"

    return
  fi

  printf '%s' "$fallback"
}

# truthy <value> — accepts true/1/yes in any case.
truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

die() {
  printf '::error title=voodu::%s\n' "$*"

  exit 1
}

note() { printf '\033[36m-----> \033[0m%s\n' "$*"; }

warn() { printf '::warning title=voodu::%s\n' "$*"; }

out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
