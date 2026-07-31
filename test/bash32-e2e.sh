#!/usr/bin/env bash
# bash 3.2（macOS 標準の /bin/bash）で SessionStart フックを end-to-end 実行する。
#
#   bash test/bash32-e2e.sh
#
# test/run.sh のスイートには入れない（run.sh 自身が mapfile を使うため、
# スイートを bash 3.2 で回すことはできない）。スイート側は
# 「ガード無しの配列展開が無い」という静的検査で守り、ここでは実際の 3.2 で
# フックを走らせて、その静的検査が現実と対応していることを確かめる。
#
# docker が無い環境では失敗する。黙って飛ばすと、この防御が「あるつもり」の
# まま消える。ローカルで回せないなら CI（.github/workflows/test.yml）に任せること。

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

IMAGE="${CTS_BASH32_IMAGE:-bash:3.2}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v docker >/dev/null 2>&1 ||
  fail "docker が無い。bash 3.2 での検証を飛ばすことは認めない。"

work="$(mktemp -d "${TMPDIR:-/tmp}/cts-bash32.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat >"$work/run.sh" <<'INNER'
set -u
bash --version | head -1
proj=/tmp/proj
rm -rf "$proj"
mkdir -p "$proj/.claude/.handoff/pending"
printf '# 引き継ぎ\nカナリア-BASH32-本文\n' \
  >"$proj/.claude/.handoff/pending/2026-07-31-1840-a.md"

printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$proj" \
  | bash /repo/scripts/handoff-check.sh >/tmp/out 2>/tmp/err
printf 'EXIT=%s\n' "$?"
printf 'STDOUT_BYTES=%s\n' "$(wc -c </tmp/out | tr -d ' ')"
printf 'STDERR_BYTES=%s\n' "$(wc -c </tmp/err | tr -d ' ')"
printf 'CANARY=%s\n' "$(grep -c 'カナリア-BASH32-本文' /tmp/out)"
printf 'PENDING=%s\n' "$(ls -A "$proj/.claude/.handoff/pending" | wc -l | tr -d ' ')"
printf 'CONSUMED=%s\n' "$(ls -A "$proj/.claude/.handoff/consumed" | wc -l | tr -d ' ')"
printf 'STDERR_TEXT<<%s\n' "$(cat /tmp/err)"

# 未消費ゼロなら無出力・終了コード 0 であること（未導入時と挙動が変わらない）。
rm -rf "$proj/.claude/.handoff/pending"
mkdir -p "$proj/.claude/.handoff/pending"
printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$proj" \
  | bash /repo/scripts/handoff-check.sh >/tmp/out2 2>/tmp/err2
printf 'EMPTY_EXIT=%s\n' "$?"
printf 'EMPTY_STDOUT_BYTES=%s\n' "$(wc -c </tmp/out2 | tr -d ' ')"
printf 'EMPTY_STDERR_BYTES=%s\n' "$(wc -c </tmp/err2 | tr -d ' ')"
INNER

out="$(docker run --rm \
  -v "$REPO_ROOT:/repo:ro" \
  -v "$work:/work:ro" \
  "$IMAGE" bash /work/run.sh 2>&1)" || fail "docker run に失敗した:
$out"

printf '%s\n' "$out"

want() {
  case "$out" in
    *"$1"*) ;;
    *) fail "$2（期待した行が無い: $1）" ;;
  esac
}

want 'version 3.2'          "bash 3.2 で走っていない"
want 'EXIT=0'               "終了コードが 0 でない"
want 'CANARY=1'             "本文が注入されていない"
want 'STDERR_BYTES=0'       "標準エラーを汚している"
want 'PENDING=0'            "pending が消費されていない"
want 'CONSUMED=1'           "consumed へ移っていない"
want 'EMPTY_EXIT=0'         "未消費ゼロで終了コードが 0 でない"
want 'EMPTY_STDOUT_BYTES=0' "未消費ゼロなのに出力がある"
want 'EMPTY_STDERR_BYTES=0' "未消費ゼロで標準エラーを汚している"

# 前方に EMPTY_ が付いた行と取り違えないよう、行頭で照合する。
case "
$out" in
  *"
STDOUT_BYTES=0"*) fail "標準出力が空である（本文が失われている）" ;;
esac

printf 'OK: bash 3.2 でフックが正しく動作した\n'
