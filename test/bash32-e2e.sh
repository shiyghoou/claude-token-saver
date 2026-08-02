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
