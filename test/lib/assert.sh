#!/usr/bin/env bash
# アサーション。失敗したら理由を標準エラーへ書き、終了コード 1 で抜ける。
# テスト関数は run.sh がサブシェルで呼ぶため、ここで exit してよい。

_fail() {
  printf '    %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-値}"
  if [ "$expected" != "$actual" ]; then
    _fail "${label}が一致しない: expected=[${expected}] actual=[${actual}]"
  fi
}

assert_ne() {
  local unexpected="$1" actual="$2" label="${3:-値}"
  if [ "$unexpected" = "$actual" ]; then
    _fail "${label}が一致してはいけない: [${actual}]"
  fi
}

assert_empty() {
  local actual="$1" label="${2:-出力}"
  if [ -n "$actual" ]; then
    _fail "${label}が空でない: [${actual}]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-出力}"
  case "$haystack" in
    *"$needle"*) ;;
    *) _fail "${label}に [${needle}] が含まれない: [${haystack}]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-出力}"
  case "$haystack" in
    *"$needle"*) _fail "${label}に [${needle}] が含まれてはいけない: [${haystack}]" ;;
  esac
}

assert_file_exists() {
  [ -e "$1" ] || _fail "ファイルが存在しない: $1"
}

assert_file_missing() {
  [ -e "$1" ] && _fail "ファイルが存在してはいけない: $1"
  return 0
}

# 出現回数を数える。install.sh の冪等性検証に使う。
# grep -c は「一致した行数」しか返さないため、同じ行に2回出ても 1 になる。
# 冪等性の検証では追記が1行に潰れた場合こそ見逃したくないので、
# grep -o で出現ごとに1行へ展開してから数える。
#
# -F は必須である。呼び出し側の needle は ".claude/.handoff/" のように
# ドットを含むため、正規表現として解釈されると「1件も無いのに1件ある」と
# 誤判定し、冪等性の検証が黙って緩む。-- は先頭ハイフンの needle のため。
#
# 制約: 改行を含む needle は grep が行単位で走るため常に 0 と数える。
# 複数行の一致を数えたい場合は、このアサーションを使ってはならない。
assert_count() {
  local expected="$1" haystack="$2" needle="$3" label="${4:-出現回数}"
  local actual
  # 空 needle の出現回数は定義できない。変数が空だった事故を 0 件や 1 件に
  # 化けさせず、その場で落とす。
  if [ -z "$needle" ]; then
    _fail "${label}の needle が空である（呼び出し側の変数が空の可能性）"
  fi
  actual=$(printf '%s\n' "$haystack" | grep -o -F -- "$needle" | wc -l | tr -d ' ')
  if [ "$expected" != "$actual" ]; then
    _fail "${label}が一致しない: expected=${expected} actual=${actual} needle=[${needle}]"
  fi
}
