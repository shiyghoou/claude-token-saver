#!/usr/bin/env bash
# Stop hook と token-report が共有する軽量キャリブレーション状態。
# Python、jq、ネットワークを呼ばず、失敗時は呼び出し側が無出力で継続できる。

CTS_CALIBRATION_STATE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null)" || CTS_CALIBRATION_STATE_SCRIPT_DIR=""
if [ -n "$CTS_CALIBRATION_STATE_SCRIPT_DIR" ] && [ -f "$CTS_CALIBRATION_STATE_SCRIPT_DIR/paths.sh" ]; then
  # shellcheck source=scripts/lib/paths.sh
  . "$CTS_CALIBRATION_STATE_SCRIPT_DIR/paths.sh"
fi

_cts_calibration_valid_integer() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

_cts_calibration_positive_integer() {
  _cts_calibration_valid_integer "${1:-}" || return 1
  [ "$1" -gt 0 ] 2>/dev/null
}

_cts_calibration_valid_session_key() {
  case "${1:-}" in
    '' | *[!0-9-]*) return 1 ;;
  esac
  case "$1" in
    -* | *-) return 1 ;;
  esac
  return 0
}

cts_calibration_config_number() {
  local config="$1" key="$2" value
  [ -n "${CTS_CALIBRATION_STATE_SCRIPT_DIR:-}" ] || return 1
  [ -f "$config" ] && [ ! -L "$config" ] && [ -r "$config" ] || return 1
  value="$(awk -v config_key="$key" \
    -f "$CTS_CALIBRATION_STATE_SCRIPT_DIR/calibration-config.awk" "$config" 2>/dev/null)" || return 1
  _cts_calibration_positive_integer "$value" || return 1
  printf '%s\n' "$value"
  return 0
}

_cts_calibration_ensure_directory() {
  local directory="$1" physical
  [ ! -L "$directory" ] || return 1
  if [ -e "$directory" ]; then
    [ -d "$directory" ] || return 1
  else
    mkdir "$directory" 2>/dev/null || return 1
  fi
  [ ! -L "$directory" ] || return 1
  physical="$(cd -P "$directory" 2>/dev/null && pwd -P)" || return 1
  [ "$physical" = "$directory" ] || return 1
  return 0
}

_cts_calibration_prepare_directory() {
  local root="$1" base calibration
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  root="$(cd -P "$root" 2>/dev/null && pwd -P)" || return 1
  base="$root/$(cts_base_rel)"
  calibration="$root/$(cts_calibration_rel)"
  _cts_calibration_ensure_directory "$base" || return 1
  _cts_calibration_ensure_directory "$calibration" || return 1
  CTS_CALIBRATION_ROOT="$root"
  CTS_CALIBRATION_DIR="$calibration"
  return 0
}

_cts_calibration_validate_sessions() {
  local path="$1" tab
  [ ! -L "$path" ] || return 1
  [ -f "$path" ] || return 1
  tab="$(printf '\t')"
  awk -F "$tab" '
    NF != 4 ||
    $1 !~ /^[0-9][0-9-]*[0-9]$/ ||
    $2 !~ /^[0-9]+$/ ||
    $3 !~ /^[0-9]+$/ ||
    $4 !~ /^[0-9]+$/ { invalid = 1 }
    END { exit invalid ? 1 : 0 }
  ' "$path" 2>/dev/null
}

_cts_calibration_validate_state() {
  local path="$1" tab
  [ ! -L "$path" ] || return 1
  [ -f "$path" ] || return 1
  tab="$(printf '=')"
  awk -F "$tab" '
    NF != 2 || ($1 != "prompted_key" && $1 != "applied_key") ||
    $2 !~ /^[0-9-]*$/ { invalid = 1 }
    $1 == "prompted_key" { prompted += 1 }
    $1 == "applied_key" { applied += 1 }
    END { exit invalid || prompted > 1 || applied > 1 ? 1 : 0 }
  ' "$path" 2>/dev/null
}

_cts_calibration_read_state() {
  local path="$1" name value
  CTS_CALIBRATION_PROMPTED_KEY=""
  CTS_CALIBRATION_APPLIED_KEY=""
  [ ! -L "$path" ] || return 1
  if [ ! -e "$path" ]; then
    return 0
  fi
  _cts_calibration_validate_state "$path" || return 1
  while IFS='=' read -r name value; do
    case "$name" in
      prompted_key) CTS_CALIBRATION_PROMPTED_KEY="$value" ;;
      applied_key) CTS_CALIBRATION_APPLIED_KEY="$value" ;;
      *) return 1 ;;
    esac
  done <"$path"
  return 0
}

_cts_calibration_atomic_write() {
  local destination="$1" content="$2" directory tmp
  [ ! -L "$destination" ] || return 1
  directory="$(dirname "$destination")"
  tmp="$(mktemp "$directory/.calibration-state.XXXXXX" 2>/dev/null)" || return 1
  [ ! -L "$tmp" ] && [ -f "$tmp" ] || {
    rm -f "$tmp" 2>/dev/null || true
    return 1
  }
  if ! printf '%s\n' "$content" >"$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp" "$destination" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

_cts_calibration_release_lock() {
  if [ -n "${CTS_CALIBRATION_LOCK_DIR:-}" ]; then
    rmdir "$CTS_CALIBRATION_LOCK_DIR" 2>/dev/null || true
  fi
  CTS_CALIBRATION_LOCK_DIR=""
}

_cts_calibration_acquire_lock() {
  local lock="$1"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 1
  mkdir "$lock" 2>/dev/null || return 1
  [ -d "$lock" ] && [ ! -L "$lock" ] || {
    rmdir "$lock" 2>/dev/null || true
    return 1
  }
  CTS_CALIBRATION_LOCK_DIR="$lock"
  return 0
}

cts_calibration_record_session() {
  local root="$1" session_key="$2" cache_read="$3" assistant_turns="$4"
  local min_sessions="$5" min_turns="$6"
  local sessions state lock tmp now tab summary session_count turn_count prompt_key
  CTS_CALIBRATION_PROMPT=0
  CTS_CALIBRATION_LOCK_DIR=""

  _cts_calibration_valid_session_key "$session_key" || return 1
  _cts_calibration_valid_integer "$cache_read" || return 1
  _cts_calibration_valid_integer "$assistant_turns" || return 1
  _cts_calibration_positive_integer "$min_sessions" || return 1
  _cts_calibration_positive_integer "$min_turns" || return 1
  _cts_calibration_prepare_directory "$root" || return 1

  sessions="$CTS_CALIBRATION_DIR/sessions.tsv"
  state="$CTS_CALIBRATION_DIR/state"
  lock="$CTS_CALIBRATION_DIR/.lock"
  if [ -e "$sessions" ] || [ -L "$sessions" ]; then
    _cts_calibration_validate_sessions "$sessions" || return 1
  fi
  if [ -e "$state" ] || [ -L "$state" ]; then
    _cts_calibration_read_state "$state" || return 1
  else
    CTS_CALIBRATION_PROMPTED_KEY=""
    CTS_CALIBRATION_APPLIED_KEY=""
  fi

  _cts_calibration_acquire_lock "$lock" || return 1
  if [ -e "$sessions" ] || [ -L "$sessions" ]; then
    _cts_calibration_validate_sessions "$sessions" || {
      _cts_calibration_release_lock
      return 1
    }
  fi
  if [ -e "$state" ] || [ -L "$state" ]; then
    _cts_calibration_read_state "$state" || {
      _cts_calibration_release_lock
      return 1
    }
  fi

  tab="$(printf '\t')"
  tmp="$(mktemp "$CTS_CALIBRATION_DIR/.sessions.tsv.XXXXXX" 2>/dev/null)" || {
    _cts_calibration_release_lock
    return 1
  }
  [ ! -L "$tmp" ] && [ -f "$tmp" ] || {
    rm -f "$tmp" 2>/dev/null || true
    _cts_calibration_release_lock
    return 1
  }
  if [ -f "$sessions" ] &&
     ! awk -F "$tab" -v wanted="$session_key" '$1 != wanted { print }' "$sessions" >"$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    _cts_calibration_release_lock
    return 1
  fi
  now="$(date +%s 2>/dev/null || printf 0)"
  _cts_calibration_valid_integer "$now" || now=0
  if ! printf '%s\t%s\t%s\t%s\n' "$session_key" "$cache_read" "$assistant_turns" \
    "$now" >>"$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    _cts_calibration_release_lock
    return 1
  fi
  if ! mv "$tmp" "$sessions" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    _cts_calibration_release_lock
    return 1
  fi

  summary="$(awk -F "$tab" '{ count += 1; turns += $3 }
    END { printf "%d%s%.0f\n", count, "'"$tab"'", turns }' "$sessions" 2>/dev/null)" || {
    _cts_calibration_release_lock
    return 1
  }
  case "$summary" in
    *"$tab"*)
      session_count="${summary%%"$tab"*}"
      turn_count="${summary#*"$tab"}"
      ;;
    *)
      _cts_calibration_release_lock
      return 1
      ;;
  esac
  _cts_calibration_valid_integer "$session_count" || {
    _cts_calibration_release_lock
    return 1
  }
  _cts_calibration_valid_integer "$turn_count" || {
    _cts_calibration_release_lock
    return 1
  }

  if [ "$session_count" -ge "$min_sessions" ] 2>/dev/null &&
     [ "$turn_count" -ge "$min_turns" ] 2>/dev/null; then
    prompt_key="${session_count}-${turn_count}-${min_sessions}-${min_turns}"
    if [ "$CTS_CALIBRATION_PROMPTED_KEY" != "$prompt_key" ] &&
       [ "$CTS_CALIBRATION_APPLIED_KEY" != "$prompt_key" ]; then
      CTS_CALIBRATION_PROMPT=1
      CTS_CALIBRATION_PROMPTED_KEY="$prompt_key"
    fi
  fi
  if ! _cts_calibration_atomic_write "$state" \
    "prompted_key=$CTS_CALIBRATION_PROMPTED_KEY
applied_key=$CTS_CALIBRATION_APPLIED_KEY"; then
    _cts_calibration_release_lock
    CTS_CALIBRATION_PROMPT=0
    return 1
  fi
  _cts_calibration_release_lock
  return 0
}
