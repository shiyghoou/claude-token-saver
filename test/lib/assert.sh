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
assert_count() {
  local expected="$1" haystack="$2" needle="$3" label="${4:-出現回数}"
  local actual
  actual=$(printf '%s\n' "$haystack" | grep -c -F -- "$needle" || true)
  if [ "$expected" != "$actual" ]; then
    _fail "${label}が一致しない: expected=${expected} actual=${actual} needle=[${needle}]"
  fi
}
