#!/usr/bin/env bash
# claude-token-saver の共通処理。フックから source される。
# jq や timeout のような、環境によって無い外部コマンドに依存しない。
# フックが依存不足で落ちるとセッション起動を妨げるため。
# （timeout は GNU coreutils であり macOS の既定環境には無い。）

# パスの単一情報源。common.sh 自身はフックから source されるため、
# 自分の位置を基準に隣を読む。
CTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=paths.sh
. "$CTS_LIB_DIR/paths.sh" || return 1

# 標準入力から受け取ったフックのペイロードを保持する。
# 読み切れなかった（タイムアウトした）ことは記録しない。「読み切れなかった＝
# 判定できない」ではなく、読めた分から目的のフィールドを取り出せることが多いため、
# 呼び出し側はこれを見て捨てる判断をしない。記録だけして誰も読まない変数は、
# 「使われている」と誤解させるだけなので置かない。
CTS_HOOK_PAYLOAD=""

# 標準入力の待ち時間の上限（秒）。フックはセッション起動の同期処理であり、
# 待たせること自体が「起動を妨げない」という設計意図に反する。
CTS_READ_TIMEOUT="${CTS_READ_TIMEOUT:-1}"

# 標準入力があれば読む。閉じない stdin でセッション起動を止めないよう、
# bash 組み込みの read -t で読む（外部の timeout に頼らない）。
cts_read_payload() {
  CTS_HOOK_PAYLOAD=""
  if [ -t 0 ]; then
    return 0
  fi

  local line rc started
  started=$SECONDS
  while :; do
    line=""
    # 標準入力が閉じられている（<&-）と read は「Bad file descriptor」を
    # 標準エラーへ書く。フックは標準エラーを汚さない契約なので握る。
    IFS= read -r -t "$CTS_READ_TIMEOUT" line 2>/dev/null
    rc=$?
    # タイムアウト・EOF いずれでも、読めた分は取り込む（末尾に改行が無い
    # 1行 JSON は rc=1 で返るため、ここを捨てると本来の入力まで失う）。
    CTS_HOOK_PAYLOAD="$CTS_HOOK_PAYLOAD$line"
    if [ "$rc" -gt 128 ]; then
      break
    fi
    [ "$rc" -eq 0 ] || break
    # 1行ずつタイムアウトが効くため、細切れに届き続ける入力では
    # 全体の待ち時間が伸びうる。総量にも上限を設ける。
    if [ $((SECONDS - started)) -ge $((CTS_READ_TIMEOUT * 3)) ]; then
      break
    fi
  done
  return 0
}

# rest の先頭から空白を捨てる。呼び出し元の rest を書き換える。
_cts_json_skip_ws() {
  while [ -n "$rest" ]; do
    case "${rest:0:1}" in
      ' ' | $'\t' | $'\n' | $'\r') rest="${rest:1}" ;;
      *) return 0 ;;
    esac
  done
  return 0
}

# 開き引用符の直後から文字列リテラルを1つ読む。読んだ値を s に、
# 残りを rest に入れる。呼び出し元の local 変数を書き換える（bash の動的スコープ）。
# 1文字ずつ回さず、引用符かバックスラッシュまでを一気に取り込むのは、
# 長いペイロードで O(長さの2乗) にしないためである。
_cts_json_take_string() {
  local part ch esc upto_q upto_b
  s=""
  while [ -n "$rest" ]; do
    upto_q="${rest%%\"*}"
    upto_b="${rest%%\\*}"
    if [ "${#upto_q}" -le "${#upto_b}" ]; then part="$upto_q"; else part="$upto_b"; fi
    if [ "${#part}" -eq "${#rest}" ]; then
      # 閉じていない文字列。壊れたペイロードなので、残り全部を値とみなす。
      s="$s$rest"
      rest=""
      return 0
    fi
    s="$s$part"
    ch="${rest:${#part}:1}"
    rest="${rest:$((${#part} + 1))}"
    [ "$ch" = '"' ] && return 0
    esc="${rest:0:1}"
    rest="${rest:1}"
    case "$esc" in
      n) s="$s"$'\n' ;;
      t) s="$s"$'\t' ;;
      r) s="$s"$'\r' ;;
      b) s="$s"$'\b' ;;
      f) s="$s"$'\f' ;;
      u) s="$s\\u${rest:0:4}"; rest="${rest:4}" ;;
      *) s="$s$esc" ;;
    esac
  done
  return 0
}

# JSON の「トップレベルの」文字列フィールドを1つ取り出す。無ければ空文字列。
# 正規の JSON パーサではないが、入れ子と文字列リテラルは読み飛ばす。
#
# grep での近似をやめたのは、入れ子オブジェクトが目的のキーより前にあると
# 入れ子側の値を拾うためである。{"nested":{"source":"compact"},"source":"startup"}
# のようなペイロードを本体が送り始めた瞬間に、compact 判定が静かに壊れる。
# jq を使わないのは、環境によって無いものへフックを依存させないためである。
cts_json_field() {
  local key="$1" rest="${2:-$CTS_HOOK_PAYLOAD}"
  local depth=0 chunk c s
  local q='"'
  # ']' を先頭に置くのは、bash のブラケット式へ ']' 自身を含めるための書き方。
  local structural="]{}[${q}"

  while [ -n "$rest" ]; do
    chunk="${rest%%[$structural]*}"
    # 構造文字が残っていない。
    [ "${#chunk}" -ne "${#rest}" ] || return 0
    c="${rest:${#chunk}:1}"
    rest="${rest:$((${#chunk} + 1))}"
    case "$c" in
      '{' | '[') depth=$((depth + 1)) ;;
      '}' | ']') depth=$((depth - 1)) ;;
      "$q")
        _cts_json_take_string
        # 直後（空白を除く）が ':' ならキー、そうでなければただの値。
        _cts_json_skip_ws
        [ "${rest:0:1}" = ':' ] || continue
        rest="${rest:1}"
        if [ "$depth" -eq 1 ] && [ "$s" = "$key" ]; then
          _cts_json_skip_ws
          # 文字列でなければ「無い」とみなす。
          if [ "${rest:0:1}" = "$q" ]; then
            rest="${rest:1}"
            _cts_json_take_string
            printf '%s' "$s"
          fi
          return 0
        fi
        ;;
    esac
  done
  return 0
}

# 引き継ぎ本文を囲む区切りの識別子。実行ごとに変える。
# 固定文字列だと、本文に終端文字列を1行書くだけで囲いを抜けられ、
# 以降が「フック自身の地の文」として読まれてしまう。
# 本文を無害化する方式にしないのは、無害化の漏れがそのまま突破になるためで、
# 書き手が事前に知り得ない識別子で囲むほうが確実である。
cts_fence_id() {
  local id=""
  if [ -r /dev/urandom ]; then
    # tr は head に切られて SIGPIPE で死ぬため終了コードは当てにならない。
    # 長さで判定する。
    id="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  fi
  if [ "${#id}" -lt 8 ]; then
    # /dev/urandom を読めない環境の退路。$RANDOM は乱数の質こそ劣るが、
    # 「本文の書き手が事前に知り得ない」という条件はここでは満たす。
    id="$(printf '%04x%04x%04x%04x' \
      "$((RANDOM))" "$((RANDOM))" "$((RANDOM))" "$(($$ & 0xffff))")"
  fi
  printf '%s' "$id"
}

# 属性値を1行の記録へ埋め込めるよう、unsafe byte を %XX へエンコードする。
# ファイル名とパスは攻撃者が決められるため、制御文字、引用符、山括弧を含む
# safe byte 以外をそのまま出力しない。NUL は Bash 文字列に保持できないため対象外。
cts_encode_attribute() {
  local value="$1" encoded="" byte hex i=0
  local LC_ALL=C

  while [ "$i" -lt "${#value}" ]; do
    byte="${value:$i:1}"
    case "$byte" in
      [A-Za-z0-9._/-]) encoded="$encoded$byte" ;;
      *)
        hex="$(printf '%s' "$byte" | od -An -t x1 2>/dev/null)" || return 1
        hex="$(printf '%s' "$hex" | tr -d '[:space:]' 2>/dev/null)" || return 1
        hex="$(printf '%s' "$hex" | tr 'a-f' 'A-F' 2>/dev/null)" || return 1
        case "$hex" in
          [0-9A-F][0-9A-F]) encoded="$encoded%$hex" ;;
          *) return 1 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$encoded"
}

# パスを dirname 相当と basename 相当に分ける。command substitution は末尾の
# 改行を落とすため、攻撃者が決められるファイル名では出力せず共通変数へ格納する。
CTS_PATH_DIRNAME=""
CTS_PATH_BASENAME=""
cts_path_parts() {
  local value="$1" dir base
  CTS_PATH_DIRNAME=""
  CTS_PATH_BASENAME=""
  case "$value" in
    */*)
      dir="${value%/*}"
      base="${value##*/}"
      [ -n "$dir" ] || dir="/"
      ;;
    *)
      dir="."
      base="$value"
      ;;
  esac
  CTS_PATH_DIRNAME="$dir"
  CTS_PATH_BASENAME="$base"
}

# パス中のシンボリックリンクを1段ずつ解決し、解決後の物理的な絶対パスを返す。
# たどれなければ 1。ハードリンクは通常ファイルと同様に扱われ、この関数で
# 別のリンク先へ解決する対象ではない。
# realpath / readlink -f を使わないのは、どちらも macOS の既定環境に無いためである
# （readlink 自体は -f 無しなら POSIX の範囲で使える）。
# 循環リンクで回り続けないよう、たどる段数に上限を置く。結果は
# CTS_RESOLVED_PATH に入り、呼び出し側が command substitution を使わずに受け取る。
CTS_RESOLVED_PATH=""
cts_resolve_path() {
  local p="$1" dir base link n=0
  CTS_RESOLVED_PATH=""
  while [ "$n" -lt 40 ]; do
    cts_path_parts "$p"
    dir="$CTS_PATH_DIRNAME"
    base="$CTS_PATH_BASENAME"
    # command substitution は末尾改行を落とすため、最後に sentinel を置いて
    # 物理パス中の末尾改行を保持してから sentinel だけを除く。
    dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P && printf '\001')" || return 1
    dir="${dir%$'\001'}"
    [ -n "$dir" ] || return 1
    case "$dir" in
      */) p="$dir$base" ;;
      *) p="$dir/$base" ;;
    esac
    [ -L "$p" ] || break
    # symlink のリンク先にも末尾改行を許す。readlink の出力を sentinel で
    # 閉じてから受け取ることで、command substitution の改行切捨てを避ける。
    link="$(readlink -- "$p" 2>/dev/null && printf '\001')" || return 1
    link="${link%$'\001'}"
    case "$link" in
      /*) p="$link" ;;
      *) p="$dir/$link" ;;
    esac
    n=$((n + 1))
  done
  [ "$n" -lt 40 ] || return 1
  CTS_RESOLVED_PATH="$p"
  return 0
}

# path が dir 自身か、その配下にあるなら 0。どちらも解決済みの絶対パスであること。
cts_path_is_within() {
  local path="$1" dir="$2"
  [ -n "$path" ] && [ -n "$dir" ] || return 1
  [ "$path" = "$dir" ] && return 0
  case "$path" in
    "$dir"/*) return 0 ;;
  esac
  return 1
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

cts_handoff_dir()  { printf '%s/%s' "$(cts_project_dir)" "$(cts_handoff_rel)"; }
cts_state_dir()    { printf '%s/%s' "$(cts_project_dir)" "$(cts_base_rel)"; }

# 直前の移動処理が成功したときの移動先。標準出力を汚さずに
# 呼び出し側へ返すための変数である（フックの stdout は契約の一部）。
CTS_CONSUMED_DEST=""
CTS_MOVED_DEST=""
CTS_RESERVED_DEST=""
CTS_RESERVED_LOCK=""

# 宛先を予約する。存在確認と mv の間に別プロセスが同じ .dupN を選ぶ
# TOCTOU を避けるため、候補ごとに mkdir をロックとして使う。
# 予約先は壊れたシンボリックリンクも「存在する」と扱う。
cts_reserve_destination() {
  local src="$1" dest_dir="$2"
  local base dest lock n=0
  CTS_RESERVED_DEST=""
  CTS_RESERVED_LOCK=""
  mkdir -p -- "$dest_dir" || return 1

  cts_path_parts "$src"
  base="$CTS_PATH_BASENAME"
  while [ "$n" -lt 10000 ]; do
    if [ "$n" -eq 0 ]; then
      dest="$dest_dir/$base"
    else
      dest="$dest_dir/${base}.dup${n}"
    fi
    lock="$dest.cts-lock"

    if mkdir "$lock" 2>/dev/null; then
      if [ -e "$dest" ] || [ -L "$dest" ]; then
        rmdir "$lock" 2>/dev/null || true
        n=$((n + 1))
        continue
      fi
      CTS_RESERVED_DEST="$dest"
      CTS_RESERVED_LOCK="$lock"
      return 0
    fi
    n=$((n + 1))
  done
  return 1
}

cts_release_destination() {
  local lock="${1:-${CTS_RESERVED_LOCK:-}}"
  [ -n "$lock" ] || return 0
  rmdir "$lock" 2>/dev/null || true
  return 0
}

# 予約済みの宛先へ移す。成功後はロックを解放する。
cts_commit_reserved_file() {
  local src="$1" dest="$2" lock="$3"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    cts_release_destination "$lock"
    return 1
  fi
  if ! mv -- "$src" "$dest"; then
    cts_release_destination "$lock"
    return 1
  fi
  cts_release_destination "$lock"
  return 0
}

# src を dest_dir へ移す。既存の同名ファイルは上書きしない。
# 成功したら CTS_MOVED_DEST に移動先を入れる。失敗したら 1。
cts_move_file() {
  local src="$1" dest_dir="$2"
  CTS_MOVED_DEST=""
  cts_reserve_destination "$src" "$dest_dir" || return 1
  if ! mv -- "$src" "$CTS_RESERVED_DEST"; then
    cts_release_destination "$CTS_RESERVED_LOCK"
    return 1
  fi
  CTS_MOVED_DEST="$CTS_RESERVED_DEST"
  cts_release_destination "$CTS_RESERVED_LOCK"
  return 0
}

# pending のファイルを consumed へ移す。呼び出し側が利用してきた
# CTS_CONSUMED_DEST と戻り値は維持し、内部だけ競合安全な移動へ委譲する。
cts_consume_file() {
  local src="$1" consumed_dir="$2"
  CTS_CONSUMED_DEST=""
  cts_move_file "$src" "$consumed_dir" || return 1
  CTS_CONSUMED_DEST="$CTS_MOVED_DEST"
  return 0
}
