#!/usr/bin/env bash
# Claude Code Stop hook。累積 cache_read が閾値へ達したときだけ、
# セッションを手動で切ることを提案する。フックの失敗で Stop を妨げない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P 2>/dev/null)" || SCRIPT_DIR=""

_cts_valid_integer() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

_cts_normalize_integer() {
  local value="${1:-}"
  _cts_valid_integer "$value" || return 1
  while [ "${value#0}" != "$value" ] && [ "${#value}" -gt 1 ]; do
    value="${value#0}"
  done
  CTS_NORMALIZED_VALUE="$value"
  return 0
}

_cts_decimal_at_most() {
  local value="$1" limit="$2"
  _cts_normalize_integer "$value" || return 1
  value="$CTS_NORMALIZED_VALUE"
  _cts_normalize_integer "$limit" || return 1
  limit="$CTS_NORMALIZED_VALUE"
  [ "${#value}" -lt "${#limit}" ] && return 0
  [ "${#value}" -gt "${#limit}" ] && return 1
  [ "$value" = "$limit" ] && return 0
  [[ "$value" < "$limit" ]]
}

_cts_positive_integer() {
  _cts_valid_integer "$1" || return 1
  [ "$1" -gt 0 ] 2>/dev/null
}

_cts_config_number() {
  local config="$1" key="$2" value
  CTS_CONFIG_VALUE=""
  [ -r "$config" ] || return 1
  value="$(awk -v config_key="$key" \
    -f "$SCRIPT_DIR/lib/suggest-session-cut-config.awk" "$config" 2>/dev/null)" || return 1
  _cts_valid_integer "$value" || return 1
  CTS_CONFIG_VALUE="$value"
  return 0
}

_cts_setting() {
  # $1: 環境変数名、$2: config key、$3: 既定値、$4: zeroを許すか、$5: 上限
  local env_name="$1" key="$2" default="$3" allow_zero="$4" max_value="${5:-}"
  local config="$CTS_ROOT/.claude/token-saver.json" value

  value="$default"
  if _cts_config_number "$config" "$key"; then
    value="$CTS_CONFIG_VALUE"
  fi
  case "$env_name" in
    CTS_SESSION_CUT_INITIAL_CACHE_READ) [ -n "${CTS_SESSION_CUT_INITIAL_CACHE_READ:-}" ] && value="$CTS_SESSION_CUT_INITIAL_CACHE_READ" ;;
    CTS_SESSION_CUT_INCREMENT_CACHE_READ) [ -n "${CTS_SESSION_CUT_INCREMENT_CACHE_READ:-}" ] && value="$CTS_SESSION_CUT_INCREMENT_CACHE_READ" ;;
    CTS_SESSION_CUT_RETENTION_DAYS) [ -n "${CTS_SESSION_CUT_RETENTION_DAYS:-}" ] && value="$CTS_SESSION_CUT_RETENTION_DAYS" ;;
    CTS_SESSION_CUT_LOG_MAX_BYTES) [ -n "${CTS_SESSION_CUT_LOG_MAX_BYTES:-}" ] && value="$CTS_SESSION_CUT_LOG_MAX_BYTES" ;;
    CTS_SESSION_CUT_LOG_BACKUPS) [ -n "${CTS_SESSION_CUT_LOG_BACKUPS:-}" ] && value="$CTS_SESSION_CUT_LOG_BACKUPS" ;;
  esac

  if [ "$allow_zero" = 1 ]; then
    _cts_valid_integer "$value" || value="$default"
  else
    _cts_positive_integer "$value" || value="$default"
  fi
  if [ -n "$max_value" ] && ! _cts_decimal_at_most "$value" "$max_value"; then
    value="$default"
  fi
  _cts_normalize_integer "$value" || value="$default"
  _cts_normalize_integer "$value" || return 1
  value="$CTS_NORMALIZED_VALUE"
  CTS_SETTING_VALUE="$value"
  return 0
}

_cts_resolve_root() {
  local cwd="$1" root parent git_root
  [ -d "$cwd" ] || return 1
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
    if [ -n "$git_root" ] && [ -d "$git_root" ]; then
      (cd -P "$git_root" 2>/dev/null && pwd -P) || return 1
      return 0
    fi
  fi
  root="$(cd -P "$cwd" 2>/dev/null && pwd -P)" || return 1
  # 非git導入先でcwdが下位ディレクトリだった場合は、.claudeを持つ祖先をrootにする。
  while :; do
    if [ -d "$root/.claude" ]; then
      printf '%s\n' "$root"
      return 0
    fi
    parent="$(dirname "$root")"
    [ "$parent" != "$root" ] || break
    root="$parent"
  done
  printf '%s\n' "$(cd -P "$cwd" 2>/dev/null && pwd -P)" || return 1
}

_cts_state_field() {
  local file="$1" key="$2" value
  CTS_STATE_VALUE=""
  [ -r "$file" ] || return 1
  value="$(awk -F= -v wanted="$key" '$1 == wanted { print $2; exit }' "$file" 2>/dev/null)" || return 1
  CTS_STATE_VALUE="$value"
  return 0
}

_cts_write_atomic() {
  local destination="$1" content="$2" directory tmp
  directory="$(dirname "$destination")"
  tmp="$(mktemp "$directory/.suggest-session-cut.XXXXXX" 2>/dev/null)" || return 1
  CTS_TMP_FILE="$tmp"
  if ! printf '%s\n' "$content" >"$tmp"; then
    rm -f "$tmp"
    CTS_TMP_FILE=""
    return 1
  fi
  if ! mv "$tmp" "$destination" 2>/dev/null; then
    rm -f "$tmp"
    CTS_TMP_FILE=""
    return 1
  fi
  CTS_TMP_FILE=""
  return 0
}

_cts_prepare_state_dir() {
  local base state physical
  base="$CTS_ROOT/$(cts_base_rel)"
  state="$CTS_ROOT/$(cts_session_cut_rel)"

  # mkdir -p は途中のsymlinkを追従するため、固定の2段を個別に作成・検査する。
  [ ! -L "$base" ] || return 1
  if [ -e "$base" ]; then
    [ -d "$base" ] || return 1
  else
    mkdir "$base" 2>/dev/null || return 1
  fi
  [ ! -L "$base" ] || return 1
  physical="$(cd -P "$base" 2>/dev/null && pwd -P)" || return 1
  [ "$physical" = "$base" ] || return 1

  [ ! -L "$state" ] || return 1
  if [ -e "$state" ]; then
    [ -d "$state" ] || return 1
  else
    mkdir "$state" 2>/dev/null || return 1
  fi
  [ ! -L "$state" ] || return 1
  physical="$(cd -P "$state" 2>/dev/null && pwd -P)" || return 1
  [ "$physical" = "$state" ] || return 1

  CTS_STATE_DIR="$state"
  CTS_STATE_PHYSICAL="$physical"
  return 0
}

_cts_enter_state_dir() {
  local current
  [ -n "${CTS_STATE_PHYSICAL:-}" ] || return 1
  cd -P "$CTS_STATE_PHYSICAL" 2>/dev/null || return 1
  current="$(pwd -P 2>/dev/null)" || return 1
  [ "$current" = "$CTS_STATE_PHYSICAL" ] || return 1
  # 以後は検査済みの物理ディレクトリをcwdとして、全て相対パスで操作する。
  CTS_STATE_DIR="."
  CTS_LOG="./events.log"
  return 0
}

_cts_plain_file_or_missing() {
  local path="$1"
  [ ! -L "$path" ] || return 1
  [ ! -e "$path" ] || [ -f "$path" ]
}

_cts_log_symlinks_absent() {
  local candidate suffix
  [ ! -L "$CTS_LOG" ] || return 1
  for candidate in "$CTS_LOG".*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    suffix="${candidate#"$CTS_LOG."}"
    _cts_positive_integer "$suffix" || continue
    [ ! -L "$candidate" ] || return 1
  done
  return 0
}

_cts_state_entries_safe() {
  local candidate
  for candidate in "$CTS_STATE_DIR"/*.cache "$CTS_STATE_DIR"/*.marker; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ ! -L "$candidate" ] && [ -f "$candidate" ] || return 1
  done
  return 0
}

_cts_stale_regular_file() {
  local path="$1" retention_days="$2" found
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  found="$(find "$path" -type f -mtime "+$retention_days" -print 2>/dev/null)"
  [ -n "$found" ]
}

_cts_cleanup_state() {
  local retention_days="$1" cache marker

  # cache/markerは片方だけを期限切れとして消すと同じ境界を再提案する。
  # ペアが揃っている間は両方が古い場合だけ一緒に掃除する。
  for cache in "$CTS_STATE_DIR"/*.cache; do
    [ -f "$cache" ] && [ ! -L "$cache" ] || continue
    marker="${cache%.cache}.marker"
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
      if _cts_stale_regular_file "$cache" "$retention_days" &&
         _cts_stale_regular_file "$marker" "$retention_days"; then
        rm -f "$cache" "$marker" 2>/dev/null || true
      fi
    elif _cts_stale_regular_file "$cache" "$retention_days"; then
      rm -f "$cache" 2>/dev/null || true
    fi
  done

  for marker in "$CTS_STATE_DIR"/*.marker; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    cache="${marker%.marker}.cache"
    if { [ ! -f "$cache" ] || [ -L "$cache" ]; } &&
       _cts_stale_regular_file "$marker" "$retention_days"; then
      rm -f "$marker" 2>/dev/null || true
    fi
  done

  # state_dir は検査済みの固定管理ディレクトリである。対象をここから広げない。
  find "$CTS_STATE_DIR" -type f \( \
    -name '*.tmp' -o -name '.suggest-session-cut.*' \
  \) -mtime "+$retention_days" -exec rm -f {} \; 2>/dev/null || true
}

_cts_lock_is_old() {
  local lock="$1" found
  found="$(find "$lock" -prune -type d -mmin +10 -print 2>/dev/null)"
  [ -n "$found" ]
}

_cts_lock_stale() {
  local lock="$1" owner pid
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  owner="$lock/owner"
  if [ -L "$owner" ] || { [ -e "$owner" ] && [ ! -f "$owner" ]; }; then
    return 1
  fi
  if [ -f "$owner" ]; then
    pid="$(awk -F= '$1 == "pid" { print $2; exit }' "$owner" 2>/dev/null)"
    if _cts_valid_integer "$pid"; then
      _cts_normalize_integer "$pid" || pid=""
      pid="${CTS_NORMALIZED_VALUE:-}"
      if [ -n "$pid" ] && [ "$pid" != 0 ] && kill -0 "$pid" 2>/dev/null; then
        return 1
      fi
    fi
  fi
  # 死んだPID、無効PID、所有者情報の無いロックでも、十分に古い場合だけ回収する。
  _cts_lock_is_old "$lock"
}

_cts_release_lock_dir() {
  local lock="$1" owner="$1/owner"
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
    rm -f "$owner" 2>/dev/null || return 1
  fi
  rmdir "$lock" 2>/dev/null
}

_cts_write_lock_owner() {
  local lock="$1" owner="$1/owner"
  [ ! -e "$owner" ] && [ ! -L "$owner" ] || return 1
  ( set -C; umask 077; printf 'pid=%s\n' "$$" >"$owner" ) 2>/dev/null || return 1
  [ -f "$owner" ] && [ ! -L "$owner" ]
}

_cts_acquire_lock() {
  local lock="$1" owner
  if mkdir "$lock" 2>/dev/null; then
    CTS_LOCK_DIR="$lock"
    if _cts_write_lock_owner "$lock"; then
      return 0
    fi
    _cts_release_lock_dir "$lock" 2>/dev/null || true
    CTS_LOCK_DIR=""
    return 1
  fi

  _cts_lock_stale "$lock" || return 1
  # stale判定直後にも同じ条件を確認し、競合中のownerを消さない。
  _cts_lock_stale "$lock" || return 1
  owner="$lock/owner"
  if [ -e "$owner" ] || [ -L "$owner" ]; then
    [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
    rm -f "$owner" 2>/dev/null || return 1
  fi
  rmdir "$lock" 2>/dev/null || return 1

  mkdir "$lock" 2>/dev/null || return 1
  CTS_LOCK_DIR="$lock"
  if _cts_write_lock_owner "$lock"; then
    return 0
  fi
  _cts_release_lock_dir "$lock" 2>/dev/null || true
  CTS_LOCK_DIR=""
  return 1
}

_cts_rollback_log_rotation() {
  local log="$1" backups="$2" rotation_tmp="$3" oldest_saved="$4"
  local moved_generations="$5" current_moved="$6" i next

  # 現行ログを移動済みなら最初に戻し、空いた世代へ低い番号から戻す。
  # 途中で戻せなければそこで止め、残りを上書きせず各パスか退避先へ保持する。
  if [ "$current_moved" = 1 ]; then
    mv "$log.1" "$log" 2>/dev/null || return 1
  fi
  for i in $moved_generations; do
    next=$((i + 1))
    mv "$log.$next" "$log.$i" 2>/dev/null || return 1
  done
  if [ "$oldest_saved" = 1 ]; then
    mv "$rotation_tmp" "$log.$backups" 2>/dev/null || return 1
  else
    rm -f "$rotation_tmp" 2>/dev/null || return 1
  fi
  return 0
}

_cts_rotate_log() {
  local max_bytes="$1" backups="$2" incoming_bytes="${3:-0}" log="$CTS_LOG"
  local size i next rotation_tmp oldest_saved moved_generations current_moved
  local candidate suffix generations
  [ -f "$log" ] || return 0
  size="$(wc -c <"$log" 2>/dev/null | tr -d '[:space:]')" || return 1
  _cts_valid_integer "$size" || return 1
  _cts_valid_integer "$incoming_bytes" || return 1
  [ $((size + incoming_bytes)) -gt "$max_bytes" ] || return 0

  rotation_tmp="$(mktemp "$CTS_STATE_DIR/.suggest-session-cut.rotate.XXXXXX" 2>/dev/null)" || return 1
  oldest_saved=0
  moved_generations=""
  current_moved=0

  if [ "$backups" -eq 0 ]; then
    if ! mv "$log" "$rotation_tmp" 2>/dev/null; then
      [ -e "$log" ] && rm -f "$rotation_tmp" 2>/dev/null
      return 1
    fi
    if rm -f "$rotation_tmp" 2>/dev/null; then
      return 0
    fi
    mv "$rotation_tmp" "$log" 2>/dev/null || true
    return 1
  fi

  # 実在する数値世代だけを列挙する。backupsが巨大でも1..Nを走査しない。
  generations=""
  for candidate in "$log".*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    suffix="${candidate#"$log."}"
    _cts_positive_integer "$suffix" || continue
    [ "$suffix" -le "$backups" ] 2>/dev/null || continue
    if [ -L "$candidate" ] || [ ! -f "$candidate" ]; then
      rm -f "$rotation_tmp" 2>/dev/null || true
      return 1
    fi
    generations="$generations $suffix"
  done
  if [ -n "$generations" ]; then
    generations="$(printf '%s\n' $generations | sort -nr 2>/dev/null)" || {
      rm -f "$rotation_tmp" 2>/dev/null || true
      return 1
    }
  fi

  # 降順に実在世代だけを移す。最古の保持上限世代は先に退避し、
  # 途中失敗時に全世代を元へ戻せるようにする。
  for i in $generations; do
    if [ "$i" -eq "$backups" ]; then
      if ! mv "$log.$i" "$rotation_tmp" 2>/dev/null; then
        [ -e "$log.$i" ] && rm -f "$rotation_tmp" 2>/dev/null
        return 1
      fi
      oldest_saved=1
      continue
    fi
    next=$((i + 1))
    if ! mv "$log.$i" "$log.$next" 2>/dev/null; then
      _cts_rollback_log_rotation "$log" "$backups" "$rotation_tmp" \
        "$oldest_saved" "$moved_generations" "$current_moved" || true
      return 1
    fi
    moved_generations="$i $moved_generations"
  done

  if ! mv "$log" "$log.1" 2>/dev/null; then
    _cts_rollback_log_rotation "$log" "$backups" "$rotation_tmp" \
      "$oldest_saved" "$moved_generations" "$current_moved" || true
    return 1
  fi
  current_moved=1

  # 全世代を移動できた場合に限り、退避した最古世代を破棄する。
  if ! rm -f "$rotation_tmp" 2>/dev/null; then
    _cts_rollback_log_rotation "$log" "$backups" "$rotation_tmp" \
      "$oldest_saved" "$moved_generations" "$current_moved" || true
    return 1
  fi
  return 0
}

_cts_exit_cleanup() {
  if [ -n "${CTS_TMP_FILE:-}" ]; then
    rm -f "$CTS_TMP_FILE" 2>/dev/null || true
  fi
  if [ -n "${CTS_LOCK_DIR:-}" ]; then
    _cts_release_lock_dir "$CTS_LOCK_DIR" 2>/dev/null || true
  fi
}

_cts_main() {
  local cwd session_id transcript root state_key cache marker state_fingerprint
  local initial increment retention_days log_max_bytes log_backups
  local total current_boundary marker_boundary marker_index boundary
  local cache_content marker_content now
  local payload_source log_entry log_entry_bytes lock_candidate
  CTS_TMP_FILE=""
  CTS_LOCK_DIR=""
  CTS_STATE_PHYSICAL=""
  trap '_cts_exit_cleanup' EXIT

  # common.shの標準入力読取・top-level JSON文字列抽出を共有する。
  # shellcheck source=scripts/lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh" || return 0
  cts_read_payload
  payload_source="$CTS_HOOK_PAYLOAD"
  [ -n "$payload_source" ] || return 0

  # common.shの軽量field抽出は完全なJSONパーサではない。必須フィールドを
  # 抽出する前に、Stop payload全体を末尾まで検証する。
  printf '%s\n' "$payload_source" | \
    awk -f "$SCRIPT_DIR/lib/suggest-session-cut-json.awk" >/dev/null 2>&1 || return 0

  cwd="$(cts_json_field cwd)"
  session_id="$(cts_json_field session_id)"
  transcript="$(cts_json_field transcript_path)"
  [ -n "$cwd" ] && [ -n "$session_id" ] && [ -n "$transcript" ] || return 0
  [ -d "$cwd" ] || return 0

  root="$(_cts_resolve_root "$cwd")" || return 0
  [ -d "$root" ] || return 0
  CTS_ROOT="$root"

  case "$transcript" in
    /*) ;;
    *) transcript="$root/$transcript" ;;
  esac
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 0

  _cts_setting CTS_SESSION_CUT_INITIAL_CACHE_READ initial_cache_read 30000000 0
  initial="$CTS_SETTING_VALUE"
  _cts_setting CTS_SESSION_CUT_INCREMENT_CACHE_READ increment_cache_read 30000000 0
  increment="$CTS_SETTING_VALUE"
  _cts_setting CTS_SESSION_CUT_RETENTION_DAYS retention_days 7 0
  retention_days="$CTS_SETTING_VALUE"
  _cts_setting CTS_SESSION_CUT_LOG_MAX_BYTES log_max_bytes 1048576 0
  log_max_bytes="$CTS_SETTING_VALUE"
  _cts_setting CTS_SESSION_CUT_LOG_BACKUPS log_backups 5 1 1000
  log_backups="$CTS_SETTING_VALUE"

  CTS_STATE_DIR=""
  _cts_prepare_state_dir || return 0
  _cts_enter_state_dir || return 0
  _cts_state_entries_safe || return 0
  _cts_log_symlinks_absent || return 0

  lock_candidate="./.suggest-session-cut.lock"
  _cts_acquire_lock "$lock_candidate" || return 0

  _cts_cleanup_state "$retention_days"

  total="$(awk -f "$SCRIPT_DIR/lib/suggest-session-cut-usage.awk" "$transcript" 2>/dev/null)" || return 0
  _cts_valid_integer "$total" || return 0

  state_fingerprint="$(printf '%s\037%s' "$session_id" "$transcript" | cksum 2>/dev/null)" || return 0
  state_key="$(printf '%s\n' "$state_fingerprint" | awk '{print $1 "-" $2}')" || return 0
  case "$state_key" in
    '' | *[!0-9-]*) return 0 ;;
  esac
  cache="$CTS_STATE_DIR/$state_key.cache"
  marker="$CTS_STATE_DIR/$state_key.marker"
  _cts_plain_file_or_missing "$cache" || return 0
  _cts_plain_file_or_missing "$marker" || return 0

  marker_index=0
  marker_boundary=0
  if [ -e "$marker" ]; then
    _cts_state_field "$marker" boundary_index || return 0
    marker_index="$CTS_STATE_VALUE"
    _cts_state_field "$marker" boundary || return 0
    marker_boundary="$CTS_STATE_VALUE"
    _cts_positive_integer "$marker_index" || return 0
    _cts_valid_integer "$marker_boundary" || return 0
  fi

  now="$(date +%s 2>/dev/null || printf 0)"
  cache_content="$(printf 'updated_at=%s\ntotal=%s' "$now" "$total")"
  if ! _cts_write_atomic "$cache" "$cache_content"; then
    return 0
  fi

  current_boundary="$(awk -v total="$total" -v initial="$initial" -v increment="$increment" \
    'BEGIN { if (total < initial) print 0; else printf "%.0f", int((total - initial) / increment) + 1 }' 2>/dev/null)" || return 0
  _cts_valid_integer "$current_boundary" || return 0
  [ "$current_boundary" -gt "$marker_index" ] || return 0

  boundary="$(awk -v initial="$initial" -v increment="$increment" -v boundary_index="$current_boundary" \
    'BEGIN { printf "%.0f", initial + ((boundary_index - 1) * increment) }' 2>/dev/null)" || return 0
  _cts_positive_integer "$boundary" || return 0

  marker_content="$(printf 'updated_at=%s\nboundary_index=%s\nboundary=%s' "$now" "$current_boundary" "$boundary")"
  if ! _cts_write_atomic "$marker" "$marker_content"; then
    return 0
  fi

  # markerを先に進める。以降のログ処理に失敗して提案を抑止した場合も、同じ境界を
  # 次のStopで即時再提案しないfail-closed側の順序にする。
  log_entry="$(printf '%s boundary=%s' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf unknown)" "$boundary")"
  log_entry_bytes="$(printf '%s\n' "$log_entry" | wc -c 2>/dev/null | tr -d '[:space:]')" || return 0
  _cts_valid_integer "$log_entry_bytes" || return 0
  _cts_rotate_log "$log_max_bytes" "$log_backups" "$log_entry_bytes" || return 0
  printf '%s\n' "$log_entry" >>"$CTS_LOG" 2>/dev/null || return 0
  printf '累積 cache_read が %s に達しました。引き継ぎを書いてから、手動で新しいセッションへ切り替えることを検討してください。/clear は自動実行しません。\n' "$boundary"
  return 0
}

# 本体をサブシェルへ隔離する。nounsetや予期しない外部コマンド失敗で本体が
# 終了しても、Stopフックの親プロセスへは必ず0を返す。stderrは契約上捨てる。
(
  _cts_main
) 2>/dev/null || true
exit 0
