#!/usr/bin/env bash
# claude-token-saver の共通処理。フックから source される。
# jq や timeout のような、環境によって無い外部コマンドに依存しない。
# フックが依存不足で落ちるとセッション起動を妨げるため。
# （timeout は GNU coreutils であり macOS の既定環境には無い。）

# 標準入力から受け取ったフックのペイロードを保持する。
CTS_HOOK_PAYLOAD=""
# ペイロードを読み切れなかった（タイムアウトした）ら 1。
# 呼び出し側はこのとき「判定できなかった」として安全側へ倒す。
CTS_PAYLOAD_TIMED_OUT=0

# 標準入力の待ち時間の上限（秒）。フックはセッション起動の同期処理であり、
# 待たせること自体が「起動を妨げない」という設計意図に反する。
CTS_READ_TIMEOUT="${CTS_READ_TIMEOUT:-1}"

# 標準入力があれば読む。閉じない stdin でセッション起動を止めないよう、
# bash 組み込みの read -t で読む（外部の timeout に頼らない）。
cts_read_payload() {
  CTS_HOOK_PAYLOAD=""
  CTS_PAYLOAD_TIMED_OUT=0
  if [ -t 0 ]; then
    return 0
  fi

  local line rc started
  started=$SECONDS
  while :; do
    line=""
    IFS= read -r -t "$CTS_READ_TIMEOUT" line
    rc=$?
    # タイムアウト・EOF いずれでも、読めた分は取り込む（末尾に改行が無い
    # 1行 JSON は rc=1 で返るため、ここを捨てると本来の入力まで失う）。
    CTS_HOOK_PAYLOAD="$CTS_HOOK_PAYLOAD$line"
    if [ "$rc" -gt 128 ]; then
      CTS_PAYLOAD_TIMED_OUT=1
      break
    fi
    [ "$rc" -eq 0 ] || break
    # 1行ずつタイムアウトが効くため、細切れに届き続ける入力では
    # 全体の待ち時間が伸びうる。総量にも上限を設ける。
    if [ $((SECONDS - started)) -ge $((CTS_READ_TIMEOUT * 3)) ]; then
      CTS_PAYLOAD_TIMED_OUT=1
      break
    fi
  done
  return 0
}

# JSON から文字列フィールドを1つ取り出す。見つからなければ空文字列。
# 正規の JSON パーサではない。フックのペイロードは Claude Code が生成する
# 平坦な構造であり、この用途では十分である。
#
# 必ず「最初の一致」を採る。本体がペイロードへ入れ子オブジェクトを足したとき、
# 貪欲マッチだと入れ子側の値を拾い、compact 判定が静かに壊れるため。
cts_json_field() {
  local key="$1" json="${2:-$CTS_HOOK_PAYLOAD}" match
  # 不一致で grep が 1 を返す。pipefail 下で代入自体が失敗すると呼び出し側の
  # ERR トラップを踏むため、ここで握って空文字列に落とす。
  match="$(
    printf '%s' "$json" |
      tr -d '\n' |
      grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" |
      head -n 1
  )" || match=""
  [ -n "$match" ] || return 0
  printf '%s' "$match" |
    sed -n 's/^"[^"]*"[[:space:]]*:[[:space:]]*"\(.*\)"$/\1/p'
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

# 直前の cts_consume_file が成功したときの移動先。標準出力を汚さずに
# 呼び出し側へ返すための変数である（フックの stdout は契約の一部）。
CTS_CONSUMED_DEST=""

# pending のファイルを consumed へ移す。既存の同名ファイルは上書きしない。
# 引き継ぎは作業の記録であり、失うと事故の調査ができなくなるため。
# 成功したら 0 を返し CTS_CONSUMED_DEST に移動先を入れる。失敗したら 1。
cts_consume_file() {
  local src="$1" consumed_dir="$2"
  CTS_CONSUMED_DEST=""
  mkdir -p -- "$consumed_dir" || return 1

  local base dest
  base="$(basename -- "$src")"
  dest="$consumed_dir/$base"

  local n=1
  while [ -e "$dest" ]; do
    dest="$consumed_dir/${base}.dup${n}"
    n=$((n + 1))
  done

  # mv は同一ファイルシステム上で原子的である。並行セッションが同じ
  # pending を掴んだ場合、勝った側だけが成功し、負けた側はここで失敗する。
  mv -- "$src" "$dest" || return 1
  CTS_CONSUMED_DEST="$dest"
  return 0
}
