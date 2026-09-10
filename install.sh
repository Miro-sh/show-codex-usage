#!/usr/bin/env bash
set -euo pipefail
umask 077

REPO_OWNER="${SHOW_CODEX_USAGE_REPO_OWNER:-nick-ma}"
REPO_NAME="${SHOW_CODEX_USAGE_REPO_NAME:-show-codex-usage}"
REPO_BRANCH="${SHOW_CODEX_USAGE_REPO_BRANCH:-main}"
SCRIPT_NAME="${SHOW_CODEX_USAGE_SCRIPT_NAME:-show_codex_usage.sh}"
COMMAND_NAME="${SHOW_CODEX_USAGE_COMMAND_NAME:-show-codex-usage}"
ALIAS_NAME="${SHOW_CODEX_USAGE_ALIAS:-scu}"
INSTALL_DIR="${SHOW_CODEX_USAGE_INSTALL_DIR:-$HOME/.local/bin}"
TARGET_PATH="${INSTALL_DIR}/${COMMAND_NAME}"
RC_FILE_OVERRIDE="${SHOW_CODEX_USAGE_RC_FILE:-}"
SOURCE_URL="${SHOW_CODEX_USAGE_SOURCE_URL:-https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/${SCRIPT_NAME}}"
LOCAL_SOURCE="${SHOW_CODEX_USAGE_SOURCE_FILE:-}"
TMP_INSTALL_FILE=""
trap '[[ -z "$TMP_INSTALL_FILE" ]] || rm -f -- "$TMP_INSTALL_FILE"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RC_MARKER_START="# >>> show-codex-usage >>>"
RC_MARKER_END="# <<< show-codex-usage <<<"

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: ${cmd} is required but not installed." >&2
    exit 1
  fi
}

detect_rc_file() {
  if [[ -n "$RC_FILE_OVERRIDE" ]]; then
    printf '%s\n' "$RC_FILE_OVERRIDE"
    return 0
  fi

  case "$(basename "${SHELL:-}")" in
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    bash)
      if [[ -f "$HOME/.bashrc" || ! -f "$HOME/.bash_profile" ]]; then
        printf '%s\n' "$HOME/.bashrc"
      else
        printf '%s\n' "$HOME/.bash_profile"
      fi
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

# POSIX single quoting keeps directory names inert in bash, zsh and sh rc files.
shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

append_shell_block() {
  local rc_file="$1"
  local rc_dir quoted_dir
  quoted_dir="$(shell_quote "$INSTALL_DIR")"

  rc_dir="$(dirname "$rc_file")"
  mkdir -p "$rc_dir"
  touch "$rc_file"

  if grep -Fq "$RC_MARKER_START" "$rc_file"; then
    return 0
  fi

  cat >>"$rc_file" <<EOF

$RC_MARKER_START
case ":\$PATH:" in
  *":"$quoted_dir":"*) ;;
  *) export PATH=$quoted_dir:"\$PATH" ;;
esac
alias $ALIAS_NAME='$COMMAND_NAME'
$RC_MARKER_END
EOF
}

main() {
  local rc_file

  require_command bash
  if [[ ! "$COMMAND_NAME" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ||
        ! "$ALIAS_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    echo "Error: invalid command or alias name." >&2
    exit 1
  fi
  if [[ "$INSTALL_DIR" != /* || "$INSTALL_DIR" == *:* || "$INSTALL_DIR" == *$'\n'* || "$INSTALL_DIR" == *$'\r'* ]]; then
    echo "Error: install directory must be absolute and contain no colon or newline." >&2
    exit 1
  fi
  if [[ -L "$TARGET_PATH" || ( -e "$TARGET_PATH" && ! -f "$TARGET_PATH" ) ]]; then
    echo "Error: install target must be a regular file, not a symlink." >&2
    exit 1
  fi

  # Prefer the reviewed checkout when running this installer from a file.
  if [[ -z "$LOCAL_SOURCE" && -z "${SHOW_CODEX_USAGE_SOURCE_URL:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    [[ ! -f "$script_dir/$SCRIPT_NAME" ]] || LOCAL_SOURCE="$script_dir/$SCRIPT_NAME"
  fi

  mkdir -p "$INSTALL_DIR"

  TMP_INSTALL_FILE="$(mktemp "${TARGET_PATH}.tmp.XXXXXX")"
  if [[ -n "$LOCAL_SOURCE" ]]; then
    cp -- "$LOCAL_SOURCE" "$TMP_INSTALL_FILE"
  else
    require_command curl
    curl -q -fsSL --proto '=https' --proto-redir '=https' \
      --connect-timeout 10 --max-time 60 "$SOURCE_URL" -o "$TMP_INSTALL_FILE"
  fi
  if [[ ! -s "$TMP_INSTALL_FILE" ]]; then
    echo "Error: downloaded script is empty." >&2
    exit 1
  fi
  bash -n "$TMP_INSTALL_FILE"
  chmod 755 "$TMP_INSTALL_FILE"
  mv -f -- "$TMP_INSTALL_FILE" "$TARGET_PATH"
  TMP_INSTALL_FILE=""

  rc_file="$(detect_rc_file)"
  append_shell_block "$rc_file"

  cat <<EOF
Installed:
  $TARGET_PATH

Shell config updated:
  $rc_file

Next:
  source "$rc_file"
  $COMMAND_NAME
  $ALIAS_NAME
EOF
}

main "$@"
