#!/usr/bin/env bash
# Claude Code Stop hook。累積 cache_read が閾値へ達したときだけ、
# セッションを手動で切ることを提案する。フックの失敗で Stop を妨げない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

_cts_valid_integer() {
  case "${1:-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
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
  # $1: 環境変数名、$2: config key、$3: 既定値、$4: zeroを許すか
  local env_name="$1" key="$2" default="$3" allow_zero="$4"
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

_cts_cleanup_state() {
  local retention_days="$1"
  # state_dir はこのフック自身が作った固定の管理ディレクトリである。
  # findの対象をここから広げない。
  find "$CTS_STATE_DIR" -type f \( \
    -name '*.cache' -o -name '*.marker' -o -name '*.tmp' -o -name '.suggest-session-cut.*' \
  \) -mtime "+$retention_days" -exec rm -f {} \; 2>/dev/null || true
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

  # ログ世代は通常ファイルだけを扱う。削除不能なディレクトリ等があれば、
  # 何も動かす前にfail-closedで終了する。
  i=1
  while [ "$i" -le "$backups" ]; do
    if { [ -e "$log.$i" ] || [ -L "$log.$i" ]; } && [ ! -f "$log.$i" ]; then
      rm -f "$rotation_tmp" 2>/dev/null || true
      return 1
    fi
    i=$((i + 1))
  done

  # 最古世代を削除せず先に退避する。以降は常に空いた宛先へ移す。
  if [ -e "$log.$backups" ] || [ -L "$log.$backups" ]; then
    if ! mv "$log.$backups" "$rotation_tmp" 2>/dev/null; then
      [ -e "$log.$backups" ] && rm -f "$rotation_tmp" 2>/dev/null
      return 1
    fi
    oldest_saved=1
  fi

  i=$((backups - 1))
  while [ "$i" -gt 0 ]; do
    next=$((i + 1))
    if [ -e "$log.$i" ] || [ -L "$log.$i" ]; then
      if ! mv "$log.$i" "$log.$next" 2>/dev/null; then
        _cts_rollback_log_rotation "$log" "$backups" "$rotation_tmp" \
          "$oldest_saved" "$moved_generations" "$current_moved" || true
        return 1
      fi
      moved_generations="$i $moved_generations"
    fi
    i=$((i - 1))
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

_cts_main() {
  local cwd session_id transcript root state_key cache marker state_fingerprint
  local initial increment retention_days log_max_bytes log_backups
  local total current_boundary marker_boundary marker_index boundary
  local cache_content marker_content now
  local payload_source log_entry log_entry_bytes
  CTS_TMP_FILE=""
  trap 'if [ -n "${CTS_TMP_FILE:-}" ]; then rm -f "$CTS_TMP_FILE"; fi' EXIT

  # common.shの標準入力読取・top-level JSON文字列抽出を共有する。
  # shellcheck source=scripts/lib/common.sh
  . "$SCRIPT_DIR/lib/common.sh" || return 0
  cts_read_payload
  payload_source="$CTS_HOOK_PAYLOAD"
  [ -n "$payload_source" ] || return 0

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
  _cts_setting CTS_SESSION_CUT_LOG_BACKUPS log_backups 5 1
  log_backups="$CTS_SETTING_VALUE"

  CTS_STATE_DIR="$root/$(cts_session_cut_rel)"
  CTS_LOG="$CTS_STATE_DIR/events.log"
  mkdir -p "$CTS_STATE_DIR" 2>/dev/null || return 0
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
