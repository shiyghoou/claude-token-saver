#!/usr/bin/env bash
# bash 3.2（macOS 標準の /bin/bash）で SessionStart フックを end-to-end 実行する。
#
#   bash test/bash32-e2e.sh
#
# test/run.sh のスイートには入れない（run.sh 自身が mapfile を使うため、
# スイートを bash 3.2 で回すことはできない）。スイート側は
# 「ガード無しの配列展開が無い」という静的検査で守り、ここでは実際の 3.2 で
# フックと token-report launcher を走らせて、静的検査が現実と対応していることを確かめる。
#
# docker が無い環境では失敗する。黙って飛ばすと、この防御が「あるつもり」の
# まま消える。ローカルで回せないなら CI（.github/workflows/test.yml）に任せること。
#
# install.sh / uninstall.sh はここでは走らせていない。両者は python3 を
# 呼ぶが、`bash:3.2` イメージ（Alpine/musl ベースの最小構成）には python3 が入って
# おらず、確認しようとしても「python3 が必要である」で即 die する。token-report は
# engine の出力契約を再現する stub python3 を置き、launcher 自体の Bash 3.2 互換、
# target root、成果物検証、既定配置を確認する。Python engine の動作は通常スイートが担う。

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
cd /tmp
bash --version | head -1
proj=/tmp/proj
rm -rf "$proj"
mkdir -p "$proj/.token-saver/handoff/pending"
# consumed は用意しない。cts_consume_file（scripts/lib/common.sh）が
# mkdir -p で自分で作るので、ここで先回りする必要は無い。
printf '# 引き継ぎ\nカナリア-BASH32-本文\n' \
  >"$proj/.token-saver/handoff/pending/2026-07-31-1840-a.md"

printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$proj" \
  | bash /repo/scripts/handoff-check.sh >/tmp/out 2>/tmp/err
printf 'EXIT=%s\n' "$?"
printf 'STDOUT_BYTES=%s\n' "$(wc -c </tmp/out | tr -d ' ')"
printf 'STDERR_BYTES=%s\n' "$(wc -c </tmp/err | tr -d ' ')"
printf 'CANARY=%s\n' "$(grep -c 'カナリア-BASH32-本文' /tmp/out)"
printf 'PENDING=%s\n' "$(ls -A "$proj/.token-saver/handoff/pending" | wc -l | tr -d ' ')"
printf 'CONSUMED=%s\n' "$(ls -A "$proj/.token-saver/handoff/consumed" | wc -l | tr -d ' ')"
printf 'STDERR_TEXT<<%s\n' "$(cat /tmp/err)"

# unsafe byte列をBash 3.2上で通し、od/tr経路、固定%XX属性、タグの一行性、
# marker非生成、フックstderr無漏出を確認する。
rm -f /tmp/cts-bash32-marker
hostile_name="$(printf '2026-07-31-1841-unsafe 日本語\t$(touch cts-bash32-marker)\n\r<%%>.md')"
hostile_path="$proj/.token-saver/handoff/pending/$hostile_name"
printf 'unsafe本文\n' >"$hostile_path"
printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$proj" \
  | bash /repo/scripts/handoff-check.sh >/tmp/unsafe-out 2>/tmp/unsafe-err
printf 'UNSAFE_EXIT=%s\n' "$?"
unsafe_expected='2026-07-31-1841-unsafe%20%E6%97%A5%E6%9C%AC%E8%AA%9E%09%24%28touch%20cts-bash32-marker%29%0A%0D%3C%25%3E.md'
printf 'UNSAFE_STDERR_BYTES=%s\n' "$(wc -c </tmp/unsafe-err | tr -d ' ')"
printf 'UNSAFE_TAG_LINES=%s\n' "$(grep -c '^<handoff:' /tmp/unsafe-out || true)"
printf 'UNSAFE_FILE_ATTR=%s\n' \
  "$(grep -c -F "file=\"$unsafe_expected\"" /tmp/unsafe-out || true)"
printf 'UNSAFE_PATH_ATTR=%s\n' \
  "$(grep -c -F "path=\"$proj/.token-saver/handoff/consumed/$unsafe_expected\"" /tmp/unsafe-out || true)"
printf 'UNSAFE_RAW_SHELL=%s\n' "$(grep -c -F '$(touch' /tmp/unsafe-out || true)"
if [ -e /tmp/cts-bash32-marker ]; then
  printf 'UNSAFE_MARKER=1\n'
else
  printf 'UNSAFE_MARKER=0\n'
fi
if [ -f "$proj/.token-saver/handoff/consumed/$hostile_name" ]; then
  printf 'UNSAFE_CONSUMED=1\n'
else
  printf 'UNSAFE_CONSUMED=0\n'
fi

# standalone consumer も制御文字・Unicodeを含む名前をそのまま移動できることを確認する。
consume_name='2026-07-31-1842-consume 日本語'
consume_name="${consume_name}"$'\t\n\r'
consume_path="$proj/.token-saver/handoff/pending/$consume_name"
printf 'standalone本文\n' >"$consume_path"
CLAUDE_PROJECT_DIR="$proj" bash /repo/scripts/handoff-consume.sh -- "$consume_path" \
  >/tmp/consume-out 2>/tmp/consume-err
printf 'CONSUME_EXIT=%s\n' "$?"
printf 'CONSUME_STDERR_BYTES=%s\n' "$(wc -c </tmp/consume-err | tr -d ' ')"
if [ -f "$proj/.token-saver/handoff/consumed/$consume_name" ]; then
  printf 'CONSUME_MOVED=1\n'
else
  printf 'CONSUME_MOVED=0\n'
fi

# standalone consumer の失敗時も、攻撃者制御の path を raw のまま stderr に出さない。
rm -f /tmp/cts-bash32-consumer-marker
consumer_fail_name="2026-07-31-1843-consumer-fail"
consumer_fail_name="${consumer_fail_name}"$' $(touch cts-bash32-consumer-marker)\n\r\t<%%>.md'
consumer_fail_path="$proj/.token-saver/handoff/pending/$consumer_fail_name"
printf 'consumer失敗本文\n' >"$consumer_fail_path"
consumer_fail_expected='2026-07-31-1843-consumer-fail%20%24%28touch%20cts-bash32-consumer-marker%29%0A%0D%09%3C%25%3E.md'
mkdir -p /tmp/fail-bin
cat >/tmp/fail-bin/mv <<'FAILMV'
#!/bin/sh
exit 1
FAILMV
chmod +x /tmp/fail-bin/mv
PATH="/tmp/fail-bin:$PATH" CLAUDE_PROJECT_DIR="$proj" \
  bash /repo/scripts/handoff-consume.sh -- "$consumer_fail_path" \
  >/tmp/consume-fail-out 2>/tmp/consume-fail-err
printf 'CONSUME_FAIL_EXIT=%s\n' "$?"
printf 'CONSUME_FAIL_STDERR_LINES=%s\n' "$(wc -l </tmp/consume-fail-err | tr -d ' ')"
printf 'CONSUME_FAIL_EXPECTED=%s\n' \
  "$(grep -c -F "消費できなかった: $proj/.token-saver/handoff/pending/$consumer_fail_expected" /tmp/consume-fail-err || true)"
printf 'CONSUME_FAIL_RAW_SHELL=%s\n' \
  "$(grep -c -F '$(touch' /tmp/consume-fail-err || true)"
if [ -e /tmp/cts-bash32-consumer-marker ]; then
  printf 'CONSUME_FAIL_MARKER=1\n'
else
  printf 'CONSUME_FAIL_MARKER=0\n'
fi
if [ -f "$consumer_fail_path" ]; then
  printf 'CONSUME_FAIL_PENDING=1\n'
else
  printf 'CONSUME_FAIL_PENDING=0\n'
fi

# 未消費ゼロなら無出力・終了コード 0 であること（未導入時と挙動が変わらない）。
rm -rf "$proj/.token-saver/handoff/pending"
mkdir -p "$proj/.token-saver/handoff/pending"
printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$proj" \
  | bash /repo/scripts/handoff-check.sh >/tmp/out2 2>/tmp/err2
printf 'EMPTY_EXIT=%s\n' "$?"
printf 'EMPTY_STDOUT_BYTES=%s\n' "$(wc -c </tmp/out2 | tr -d ' ')"
printf 'EMPTY_STDERR_BYTES=%s\n' "$(wc -c </tmp/err2 | tr -d ' ')"

# bash:3.2 image には python3 が無いので、engine の最小出力契約だけを再現する。
mkdir -p /tmp/fake-bin
cat >/tmp/fake-bin/python3 <<'STUB'
#!/usr/bin/env bash
set -u
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || exit 64
      out="$2"
      shift 2
      ;;
    --out=*)
      out="${1#--out=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$out" ] || exit 64
printf '## 計測条件\n\ncanary: BASH32-TOKEN-REPORT\n' >"$out"
printf 'engine temporary success should be hidden\n'
STUB
chmod +x /tmp/fake-bin/python3

PATH="/tmp/fake-bin:$PATH" CTS_TOKEN_REPORT_TARGET_ROOT="$proj" \
  bash /repo/scripts/token-report.sh --days 1 >/tmp/report-out 2>/tmp/report-err
printf 'REPORT_EXIT=%s\n' "$?"
printf 'REPORT_STDERR_BYTES=%s\n' "$(wc -c </tmp/report-err | tr -d ' ')"
printf 'REPORT_STDERR_TEXT<<%s\n' "$(cat /tmp/report-err)"
printf 'REPORT_COUNT=%s\n' \
  "$(find "$proj/.token-saver/token-reports" -type f -name '*.md' | wc -l | tr -d ' ')"
printf 'REPORT_CANARY=%s\n' \
  "$(grep -R -c 'BASH32-TOKEN-REPORT' "$proj/.token-saver/token-reports" | awk -F: '{n += $NF} END {print n + 0}')"
printf 'REPORT_SUCCESS_LINES=%s\n' "$(grep -c '^書き出しました: ' /tmp/report-out)"
printf 'REPORT_ENGINE_LEAK=%s\n' "$(grep -c 'engine temporary success' /tmp/report-out)"
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
want 'UNSAFE_EXIT=0'        "unsafe入力で終了コードが 0 でない"
want 'UNSAFE_STDERR_BYTES=0' "unsafe入力で標準エラーを汚している"
want 'UNSAFE_TAG_LINES=1'   "unsafe入力で開始タグが一行でない"
want 'UNSAFE_FILE_ATTR=1'   "unsafe入力のfile属性が固定値でない"
want 'UNSAFE_PATH_ATTR=1'   "unsafe入力のpath属性が固定値でない"
want 'UNSAFE_RAW_SHELL=0'   "unsafe入力のraw shell文字列が漏れている"
want 'UNSAFE_MARKER=0'      "unsafe入力でshell markerが作成された"
want 'UNSAFE_CONSUMED=1'    "unsafe入力の実体名が保持されていない"
want 'CONSUME_EXIT=0'       "standalone consumer の終了コードが 0 でない"
want 'CONSUME_STDERR_BYTES=0' "standalone consumer が標準エラーを汚している"
want 'CONSUME_MOVED=1'      "standalone consumer が名前を保持して移動していない"
want 'CONSUME_FAIL_EXIT=1'  "standalone consumer の失敗を終了コードで示していない"
want 'CONSUME_FAIL_STDERR_LINES=1' "consumer失敗時stderrが一行でない"
want 'CONSUME_FAIL_EXPECTED=1' "consumer失敗時stderrのエンコード済みpathが無い"
want 'CONSUME_FAIL_RAW_SHELL=0' "consumer失敗時stderrにraw shell文字列が漏れている"
want 'CONSUME_FAIL_MARKER=0' "consumer失敗時にshell markerが作成された"
want 'CONSUME_FAIL_PENDING=1' "consumer失敗時にpendingファイルが失われた"
want 'EMPTY_EXIT=0'         "未消費ゼロで終了コードが 0 でない"
want 'EMPTY_STDOUT_BYTES=0' "未消費ゼロなのに出力がある"
want 'EMPTY_STDERR_BYTES=0' "未消費ゼロで標準エラーを汚している"
want 'REPORT_EXIT=0'         "token-report launcher の終了コードが 0 でない"
want 'REPORT_STDERR_BYTES=0' "token-report launcher が標準エラーを汚している"
want 'REPORT_COUNT=1'        "導入先に token-report が1件作られていない"
want 'REPORT_CANARY=1'       "token-report の内容が導入先へ保存されていない"
want 'REPORT_SUCCESS_LINES=1' "token-report の成功メッセージが1行でない"
want 'REPORT_ENGINE_LEAK=0'  "engine の一時成功メッセージが漏れている"

# 前方に EMPTY_ が付いた行と取り違えないよう、行頭で照合する。
case "
$out" in
  *"
STDOUT_BYTES=0"*) fail "標準出力が空である（本文が失われている）" ;;
esac

printf 'OK: bash 3.2 でフックと token-report launcher が正しく動作した\n'
