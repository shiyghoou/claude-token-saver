#!/usr/bin/env bash
# 明示承認されたキャリブレーションだけを設定へ適用する。

set -uo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/paths.sh
. "$SOURCE_DIR/lib/paths.sh" || exit 1

if [ "$#" -ne 1 ] || [ "$1" != "--apply" ]; then
  printf 'usage: token-calibrate.sh --apply\n' >&2
  exit 64
fi

find_target_root() {
  local current parent git_root
  if [ -n "${CTS_TOKEN_CALIBRATE_TARGET_ROOT:-}" ]; then
    (cd -- "$CTS_TOKEN_CALIBRATE_TARGET_ROOT" 2>/dev/null && pwd -P)
    return $?
  fi
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
    if [ -n "$git_root" ]; then
      (cd -- "$git_root" 2>/dev/null && pwd -P)
      return $?
    fi
  fi
  current="$(pwd -P)" || return 1
  while :; do
    if [ -e "$current/.git" ] || [ -d "$current/.claude" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    if [ "$parent" = "$current" ]; then
      printf '%s\n' "$(pwd -P)"
      return 0
    fi
    current="$parent"
  done
}

REPO_ROOT="$(find_target_root)" || {
  printf '計測対象のリポジトリルートを解決できません\n' >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || {
  printf 'python3 が必要です\n' >&2
  exit 1
}

exec python3 -B "$SOURCE_DIR/apply-token-calibration.py" \
  --root "$REPO_ROOT" \
  --latest "$REPO_ROOT/$(cts_base_rel)/calibration/latest.json"
