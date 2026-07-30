#!/usr/bin/env bash
# claude-token-saver の共通処理。フックから source される。
# 外部コマンド（jq 等）に依存しない。フックが依存不足で落ちるとセッション起動を妨げるため。

# 標準入力から受け取ったフックのペイロードを保持する。
CTS_HOOK_PAYLOAD=""

# 標準入力があれば読む。無くてもブロックしないよう、タイムアウト付きで読む。
cts_read_payload() {
  if [ -t 0 ]; then
    CTS_HOOK_PAYLOAD=""
    return 0
  fi
  CTS_HOOK_PAYLOAD="$(timeout 5 cat 2>/dev/null || true)"
}

# JSON から文字列フィールドを1つ取り出す。見つからなければ空文字列。
# 正規の JSON パーサではない。フックのペイロードは Claude Code が生成する
# 平坦な構造であり、この用途では十分である。
cts_json_field() {
  local key="$1" json="${2:-$CTS_HOOK_PAYLOAD}"
  printf '%s' "$json" |
    tr -d '\n' |
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" |
    head -n 1
}

# 導入先リポジトリのルート。CLAUDE_PROJECT_DIR → ペイロードの cwd → カレント。
cts_project_dir() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  local cwd
  cwd="$(cts_json_field cwd)"
  if [ -n "$cwd" ] && [ -d "$cwd" ]; then
    printf '%s' "$cwd"
    return 0
  fi
  printf '%s' "$PWD"
}

cts_handoff_dir()  { printf '%s/.claude/.handoff' "$(cts_project_dir)"; }
cts_state_dir()    { printf '%s/.claude/.token-saver' "$(cts_project_dir)"; }

# pending のファイルを consumed へ移す。既存の同名ファイルは上書きしない。
# 引き継ぎは作業の記録であり、失うと事故の調査ができなくなるため。
cts_consume_file() {
  local src="$1" consumed_dir="$2"
  mkdir -p "$consumed_dir" || return 1

  local base dest
  base="$(basename "$src")"
  dest="$consumed_dir/$base"

  local n=1
  while [ -e "$dest" ]; do
    dest="$consumed_dir/${base}.dup${n}"
    n=$((n + 1))
  done

  mv "$src" "$dest"
}
