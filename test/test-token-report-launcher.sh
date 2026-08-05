#!/usr/bin/env bash
# token-report.sh launcher の契約 fixture。実リポジトリ配下へは書かず、
# fixture 内の scripts/measure-token-usage.py wrapper と固定 date で振る舞いを検証する。

set -u

_fixture() {
  FIXTURE_HOME="$TEST_TMP/home"
  FIXTURE_REPO="$TEST_TMP/fixture repo"
  FIXTURE_SCRIPTS="$FIXTURE_REPO/scripts"
  FIXTURE_LIB="$FIXTURE_SCRIPTS/lib"
  FIXTURE_BIN="$TEST_TMP/bin"
  FIXTURE_LOG="$TEST_TMP/engine-args.log"
  mkdir -p "$FIXTURE_HOME" "$FIXTURE_REPO/.git" "$FIXTURE_SCRIPTS" "$FIXTURE_LIB" "$FIXTURE_BIN"

  cp "$REPO_ROOT/scripts/token-report.sh" "$FIXTURE_SCRIPTS/token-report.sh"
  cp "$REPO_ROOT/scripts/lib/paths.sh" "$FIXTURE_LIB/paths.sh"
  chmod +x "$FIXTURE_SCRIPTS/token-report.sh"

  cat >"$FIXTURE_SCRIPTS/measure-token-usage.py" <<'PYEOF'
#!/usr/bin/env python3
import os
import sys


def parse_out(argv):
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--out":
            if index + 1 < len(argv):
                return argv[index + 1]
            return None
        if arg.startswith("--out="):
            return arg.split("=", 1)[1]
        index += 1
    return None


def main():
    argv = sys.argv[1:]
    log_path = os.environ.get("CTS_LAUNCHER_LOG")
    if log_path:
        with open(log_path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(argv))
            handle.write("\n")

    mode = os.environ.get("CTS_ENGINE_MODE", "report")
    out_path = parse_out(argv)
    if out_path and mode in ("report", "empty"):
        try:
            with open(out_path, "w", encoding="utf-8") as handle:
                if mode == "report":
                    handle.write("# Claude Code トークン計測レポート\n\n")
                    handle.write("## 計測条件\n\n")
                    handle.write("- fixture: launcher\n")
                    handle.write("- canary: " + os.environ.get("CTS_ENGINE_CANARY", "default") + "\n")
                else:
                    handle.write("")
            if os.environ.get("CTS_REPORT_MTIME") == "rollback":
                os.utime(out_path, (1, 1))
        except OSError as exc:
            print(f"cannot write report: {exc}", file=sys.stderr)
            return 1

    if "--calibrate" in argv and mode != "touchless":
        snapshot_mode = os.environ.get("CTS_SNAPSHOT_MODE", "regular")
        snapshot_dir = os.path.join(os.getcwd(), ".token-saver", "calibration")
        snapshot_path = os.path.join(snapshot_dir, "latest.json")
        if snapshot_mode != "missing":
            os.makedirs(snapshot_dir, exist_ok=True)
            if snapshot_mode == "symlink":
                payload = os.path.join(snapshot_dir, "payload.json")
                with open(payload, "w", encoding="utf-8") as handle:
                    handle.write('{"fixture": true}')
                os.symlink(payload, snapshot_path)
            else:
                with open(snapshot_path, "w", encoding="utf-8") as handle:
                    handle.write("" if snapshot_mode == "empty" else '{"fixture": true}')

    exit_code = int(os.environ.get("CTS_ENGINE_EXIT", "0"))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
PYEOF
  chmod +x "$FIXTURE_SCRIPTS/measure-token-usage.py"

  cat >"$FIXTURE_BIN/date" <<'SHEOF'
#!/bin/bash
if [ "${1:-}" = "+%Y%m%d-%H%M%S" ]; then
  if [ "${CTS_DATE_FAIL:-}" = "1" ]; then
    exit 23
  fi
  printf '%s\n' "${CTS_FAKE_DATE:-20260801-123456}"
  exit 0
fi
exec /bin/date "$@"
SHEOF
  chmod +x "$FIXTURE_BIN/date"
}

_install_failing_wrapper() {
  tool="$1"
  env_name="$2"
  target="$(command -v "$tool")"
  cat >"$FIXTURE_BIN/$tool" <<EOF
#!/bin/bash
if [ "\${$env_name:-}" = "1" ]; then
  exit 29
fi
exec "$target" "\$@"
EOF
  chmod +x "$FIXTURE_BIN/$tool"
}

_run_launcher() {
  (
    cd "$FIXTURE_REPO" &&
    PATH="$FIXTURE_BIN:/usr/bin:/bin" \
      CTS_LAUNCHER_LOG="$FIXTURE_LOG" \
      "$BASH" "$FIXTURE_SCRIPTS/token-report.sh" "$@"
  )
}

_run_launcher_from_subdir() {
  subdir="$1"
  shift
  (
    cd "$FIXTURE_REPO/$subdir" &&
    PATH="$FIXTURE_BIN:/usr/bin:/bin" \
      CTS_LAUNCHER_LOG="$FIXTURE_LOG" \
      "$BASH" "$FIXTURE_SCRIPTS/token-report.sh" "$@"
  )
}

_install_path_wrapper() {
  tool="$1"
  target="$(command -v "$tool")"
  cat >"$FIXTURE_BIN/$tool" <<EOF
#!/bin/bash
exec "$target" "\$@"
EOF
  chmod +x "$FIXTURE_BIN/$tool"
}

_run_launcher_without_python() {
  for tool in basename dirname mkdir mktemp rm sed; do
    _install_path_wrapper "$tool"
  done
  (
    cd "$FIXTURE_REPO" &&
    PATH="$FIXTURE_BIN" \
      CTS_LAUNCHER_LOG="$FIXTURE_LOG" \
      "$BASH" "$FIXTURE_SCRIPTS/token-report.sh" "$@"
  )
}

test_既定のtoken_reportsへ日時付きレポートを作る() {
  _fixture
  _run_launcher >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  out="$FIXTURE_REPO/.token-saver/token-reports/20260801-123456.md"
  assert_eq "0" "$status" "既定出力の終了コード"
  assert_file_exists "$out"
  report="$(cat "$out")"
  assert_contains "$report" "## 計測条件" "既定レポート"
}

test_同じ秒の既存レポートを上書きせず連番にする() {
  _fixture
  mkdir -p "$FIXTURE_REPO/.token-saver/token-reports"
  ln -s "$TEST_TMP/missing-target" \
    "$FIXTURE_REPO/.token-saver/token-reports/20260801-123456.md"
  _run_launcher >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  out="$FIXTURE_REPO/.token-saver/token-reports/20260801-123456-2.md"
  [ -L "$FIXTURE_REPO/.token-saver/token-reports/20260801-123456.md" ] ||
    _fail "連番衝突の元になった dangling symlink が消えている"
  assert_eq "0" "$status" "連番出力の終了コード"
  assert_file_exists "$out"
}

test_explicit_outを使い親ディレクトリを勝手に作らない() {
  _fixture
  out="$TEST_TMP/missing/out/report.md"
  _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  err="$(cat "$TEST_TMP/launcher.err")"
  assert_eq "1" "$status" "explicit out の終了コード"
  assert_file_missing "$out"
  assert_file_missing "$TEST_TMP/missing/out"
  assert_file_missing "$FIXTURE_LOG" "親未作成時に起動されたengineログ"
  assert_contains "$err" "cannot write report" "親未作成エラー"
}

test_clock_rollback後のexplicit_outでも今回レポートを採用する() {
  _fixture
  out="$TEST_TMP/rollback-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- canary: old\n' >"$out"
  CTS_ENGINE_CANARY=new CTS_REPORT_MTIME=rollback \
    _run_launcher --out "$out" >"$TEST_TMP/launcher.out" 2>"$TEST_TMP/launcher.err"
  status=$?
  report="$(cat "$out")"
  output="$(cat "$TEST_TMP/launcher.out")"
  assert_eq "0" "$status" "clock rollback後のexplicit out終了コード"
  assert_contains "$report" "canary: new" "clock rollback後の最終レポート"
  assert_not_contains "$report" "canary: old" "clock rollback後に残った旧レポート"
  assert_contains "$output" "書き出しました: $out" "clock rollback後の成功表示"
}

test_explicit_outはengineへ最終パスでなくprivate_tempを渡す() {
  _fixture
  parent="$TEST_TMP/explicit-out"
  mkdir -p "$parent"
  out="$parent/report.md"
  CTS_ENGINE_CANARY=private-temp \
    _run_launcher --days 3 --out "$out" --top 7 >"$TEST_TMP/launcher.out" 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  report="$(cat "$out")"
  private_files="$(find "$parent" -maxdepth 1 -name '.token-report.*' -print)"
  assert_eq "0" "$status" "explicit out private tempの終了コード"
  assert_contains "$args" $'--out\n'"$parent/.token-report." "engineへ渡したprivate temp"
  assert_not_contains "$args" "$out" "engineへ最終パスを渡していない"
  assert_contains "$report" "canary: private-temp" "private temp経由の最終レポート"
  assert_empty "$private_files" "成功後に残ったexplicit out用private temp"
}

test_out_equalsもengineへprivate_tempを渡す() {
  _fixture
  parent="$TEST_TMP/explicit-out-equals"
  mkdir -p "$parent"
  out="$parent/report.md"
  CTS_ENGINE_CANARY=equals \
    _run_launcher --days 5 --out="$out" --all-projects --paths --top 9 \
      >"$TEST_TMP/launcher.out" 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  report="$(cat "$out")"
  private_files="$(find "$parent" -maxdepth 1 -name '.token-report.*' -print)"
  assert_eq "0" "$status" "out= private tempの終了コード"
  assert_contains "$args" $'--days\n5\n--out='"$parent/.token-report." "out=形式と引数順序"
  assert_contains "$args" $'--all-projects\n--paths\n--top\n9' "out=後続引数の順序"
  assert_not_contains "$args" "$out" "out=でengineへ最終パスを渡していない"
  assert_contains "$report" "canary: equals" "out= private temp経由の最終レポート"
  assert_empty "$private_files" "成功後に残ったout=用private temp"
}

test_relative_out_VALUEはrepo_root基準で解決する() {
  _fixture
  mkdir -p "$FIXTURE_REPO/work" "$FIXTURE_REPO/relative"
  out="$FIXTURE_REPO/relative/path.md"
  CTS_ENGINE_CANARY=relative-value \
    _run_launcher_from_subdir work --out relative/path.md \
      >"$TEST_TMP/launcher.out" 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  report="$(cat "$out")"
  assert_eq "0" "$status" "relative --out VALUEの終了コード"
  assert_contains "$report" "canary: relative-value" "repo root基準のrelativeレポート"
  assert_contains "$args" $'--out\n'"$FIXTURE_REPO/relative/.token-report." \
    "relative --out VALUEのengine private temp"
  assert_not_contains "$args" "relative/path.md" "engineへrelative最終パスを渡していない"
  assert_contains "$(cat "$TEST_TMP/launcher.out")" \
    "書き出しました: relative/path.md" "relative --out VALUEの成功表示"
  assert_file_missing "$FIXTURE_REPO/work/relative/path.md" "呼出元subdirへのrelative出力"
  assert_empty "$(find "$FIXTURE_REPO/relative" -maxdepth 1 -name '.token-report.*' -print)" \
    "relative --out VALUEのprivate temp"
}

test_relative_out_equalsはrepo_root基準で解決する() {
  _fixture
  mkdir -p "$FIXTURE_REPO/work" "$FIXTURE_REPO/relative-equals"
  out="$FIXTURE_REPO/relative-equals/path.md"
  CTS_ENGINE_CANARY=relative-equals \
    _run_launcher_from_subdir work --days 4 --out=relative-equals/path.md --top 6 \
      >"$TEST_TMP/launcher.out" 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  report="$(cat "$out")"
  assert_eq "0" "$status" "relative --out=VALUEの終了コード"
  assert_contains "$report" "canary: relative-equals" "repo root基準のrelative out=レポート"
  assert_contains "$args" $'--days\n4\n--out='"$FIXTURE_REPO/relative-equals/.token-report." \
    "relative --out=VALUEのengine private temp"
  assert_contains "$args" $'--out='"$FIXTURE_REPO/relative-equals/.token-report." \
    "relative --out=VALUEの形式"
  assert_not_contains "$args" "relative-equals/path.md" "engineへrelative out=最終パスを渡していない"
  assert_contains "$(cat "$TEST_TMP/launcher.out")" \
    "書き出しました: relative-equals/path.md" "relative --out=VALUEの成功表示"
  assert_file_missing "$FIXTURE_REPO/work/relative-equals/path.md" "呼出元subdirへのrelative out=出力"
  assert_empty "$(find "$FIXTURE_REPO/relative-equals" -maxdepth 1 -name '.token-report.*' -print)" \
    "relative --out=VALUEのprivate temp"
}

test_daysとall_projectsとpathsをengineへ渡す() {
  _fixture
  _run_launcher --days 3 --all-projects --paths --top 7 >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  assert_eq "0" "$status" "引数転送の終了コード"
  assert_contains "$args" "--days
3" "days 引数"
  assert_contains "$args" "--all-projects" "all-projects 引数"
  assert_contains "$args" "--paths" "paths 引数"
  assert_contains "$args" "--top
7" "top 引数"
  assert_contains "$args" "--out
/tmp/cts-token-report-output." "既定 out 引数"
  assert_not_contains "$args" "$FIXTURE_REPO/.token-saver/token-reports/20260801-123456.md" \
    "既定 out は最終配置前の一時ファイル"
}

test_calibrateを渡し今回生成のsnapshotを検査する() {
  _fixture
  _run_launcher --calibrate >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  args="$(cat "$FIXTURE_LOG")"
  snapshot="$FIXTURE_REPO/.token-saver/calibration/latest.json"
  assert_eq "0" "$status" "calibrate の終了コード"
  assert_contains "$args" "--calibrate" "calibrate 引数"
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || _fail "calibrate snapshot が通常ファイルでない"
  [ -s "$snapshot" ] || _fail "calibrate snapshot が空である"
}

test_calibrateでsnapshotが未生成なら既定レポートを残さず失敗する() {
  _fixture
  out="$TEST_TMP/calibrate-missing-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/calibrate-missing-before.md"
  CTS_SNAPSHOT_MODE=missing _run_launcher --calibrate --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "snapshot未生成の終了コード"
  cmp -s "$out" "$TEST_TMP/calibrate-missing-before.md" ||
    _fail "snapshot未生成時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "snapshot未生成時のprivate temp"
}

test_calibrateでsymlink_snapshotを拒否する() {
  _fixture
  out="$TEST_TMP/calibrate-symlink-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/calibrate-symlink-before.md"
  CTS_SNAPSHOT_MODE=symlink _run_launcher --calibrate --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "symlink snapshot の終了コード"
  cmp -s "$out" "$TEST_TMP/calibrate-symlink-before.md" ||
    _fail "symlink snapshot時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "symlink snapshot時のprivate temp"
}

test_calibrateで前回snapshotだけなら既定レポートを残さず失敗する() {
  _fixture
  snapshot_dir="$FIXTURE_REPO/.token-saver/calibration"
  mkdir -p "$snapshot_dir"
  printf '{"fixture": "stale"}' >"$snapshot_dir/latest.json"
  touch -t 200001010000 "$snapshot_dir/latest.json"
  out="$TEST_TMP/calibrate-stale-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/calibrate-stale-before.md"
  CTS_SNAPSHOT_MODE=missing _run_launcher --calibrate --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "stale snapshot の終了コード"
  cmp -s "$out" "$TEST_TMP/calibrate-stale-before.md" ||
    _fail "stale snapshot時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "stale snapshot時のprivate temp"
}

test_calibrateで未来mtimeの既存snapshotを再利用しない() {
  _fixture
  snapshot_dir="$FIXTURE_REPO/.token-saver/calibration"
  mkdir -p "$snapshot_dir"
  printf '{"fixture": "future-stale"}' >"$snapshot_dir/latest.json"
  touch -t 299912312359 "$snapshot_dir/latest.json"
  out="$TEST_TMP/calibrate-future-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/calibrate-future-before.md"
  CTS_SNAPSHOT_MODE=missing _run_launcher --calibrate --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "未来mtime snapshotの終了コード"
  cmp -s "$out" "$TEST_TMP/calibrate-future-before.md" ||
    _fail "未来mtime snapshot時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "未来mtime snapshot時のprivate temp"
}

test_計測器が非ゼロならlauncherも非ゼロにする() {
  _fixture
  out="$TEST_TMP/engine-error-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/engine-error-before.md"
  CTS_ENGINE_MODE=touchless CTS_ENGINE_EXIT=17 \
    _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_eq "17" "$status" "計測器エラー伝播"
  cmp -s "$out" "$TEST_TMP/engine-error-before.md" ||
    _fail "計測器非ゼロ時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "計測器非ゼロ時のprivate temp"
}

test_計測器が非ゼロなら既定出力ディレクトリを残さない() {
  _fixture
  CTS_ENGINE_MODE=touchless CTS_ENGINE_EXIT=17 \
    _run_launcher >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_eq "17" "$status" "計測器エラー伝播"
  assert_file_missing "$FIXTURE_REPO/.token-saver/token-reports"
}

test_成功rcでも空レポートなら失敗にする() {
  _fixture
  out="$TEST_TMP/empty-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/empty-before.md"
  CTS_ENGINE_MODE=empty _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  err="$(cat "$TEST_TMP/launcher.err")"
  assert_ne "0" "$status" "空レポート拒否"
  assert_contains "$err" "空" "空レポートの理由"
  cmp -s "$out" "$TEST_TMP/empty-before.md" ||
    _fail "空レポート時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "空レポート時のprivate temp"
}

test_前回の既存レポートだけで成功扱いにしない() {
  _fixture
  out="$TEST_TMP/stale-report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- stale\n' >"$out"
  cp "$out" "$TEST_TMP/stale-before.md"
  touch -t 299912312359 "$out"
  CTS_ENGINE_MODE=touchless _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "freshness 検査"
  cmp -s "$out" "$TEST_TMP/stale-before.md" ||
    _fail "touchless engine時に未来mtimeの既存レポートが変更された"
  assert_empty "$(find "$TEST_TMP" -maxdepth 1 -name '.token-report.*' -print)" \
    "touchless engine時のprivate temp"
}

test_symlinkのexplicit_outを拒否し参照先を変更しない() {
  _fixture
  parent="$TEST_TMP/symlink-out"
  mkdir -p "$parent"
  target="$parent/target.md"
  out="$parent/report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- target-old\n' >"$target"
  cp "$target" "$TEST_TMP/symlink-before.md"
  ln -s "$target" "$out"
  CTS_ENGINE_CANARY=new _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "symlink explicit out拒否"
  [ -L "$out" ] || _fail "explicit outのsymlinkが置き換えられた"
  cmp -s "$target" "$TEST_TMP/symlink-before.md" ||
    _fail "explicit out symlinkの参照先が変更された"
  assert_file_missing "$FIXTURE_LOG" "symlink拒否後に起動されたengineログ"
  assert_empty "$(find "$parent" -maxdepth 1 -name '.token-report.*' -print)" \
    "symlink拒否後のprivate temp"
}

test_explicit_outの最終mv失敗でも既存出力を保持する() {
  _fixture
  parent="$TEST_TMP/mv-out"
  mkdir -p "$parent"
  out="$parent/report.md"
  printf '# Claude Code トークン計測レポート\n\n## 計測条件\n\n- old\n' >"$out"
  cp "$out" "$TEST_TMP/mv-before.md"
  _install_failing_wrapper mv CTS_MV_FAIL
  CTS_ENGINE_CANARY=new CTS_MV_FAIL=1 \
    _run_launcher --out "$out" >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "explicit out最終mv失敗"
  cmp -s "$out" "$TEST_TMP/mv-before.md" ||
    _fail "最終mv失敗時に既存のexplicitレポートが変更された"
  assert_empty "$(find "$parent" -maxdepth 1 -name '.token-report.*' -print)" \
    "最終mv失敗後のprivate temp"
}

test_python3が無ければ理由を表示して失敗する() {
  _fixture
  _run_launcher_without_python >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  err="$(cat "$TEST_TMP/launcher.err")"
  assert_ne "0" "$status" "python3 不在"
  assert_contains "$err" "python3" "python3 文言"
  assert_contains "$err" "見つかりません" "python3 不在理由"
}

test_python3が無ければ既定出力ディレクトリを残さない() {
  _fixture
  _run_launcher_without_python >/dev/null 2>"$TEST_TMP/launcher.err"
  status=$?
  assert_ne "0" "$status" "python3 不在"
  assert_file_missing "$FIXTURE_REPO/.token-saver/token-reports"
}

test_同時起動でも同名レポートを上書きしない() {
  _fixture
  CTS_ENGINE_CANARY=first _run_launcher >"$TEST_TMP/first.out" 2>"$TEST_TMP/first.err" &
  first_pid=$!
  CTS_ENGINE_CANARY=second _run_launcher >"$TEST_TMP/second.out" 2>"$TEST_TMP/second.err" &
  second_pid=$!
  first_status=0
  second_status=0
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?
  report_dir="$FIXTURE_REPO/.token-saver/token-reports"
  report_count="$(find "$report_dir" -maxdepth 1 -type f -name '20260801-123456*.md' | wc -l | tr -d ' ')"
  combined="$(find "$report_dir" -maxdepth 1 -type f -name '20260801-123456*.md' -exec cat {} \;)"
  assert_eq "0" "$first_status" "同時起動1の終了コード"
  assert_eq "0" "$second_status" "同時起動2の終了コード"
  assert_eq "2" "$report_count" "同時起動のレポート件数"
  assert_contains "$combined" "canary: first" "同時起動1の内容"
  assert_contains "$combined" "canary: second" "同時起動2の内容"
}

test_date失敗時に作成した空ディレクトリを残さない() {
  _fixture
  CTS_DATE_FAIL=1 _run_launcher >/dev/null 2>"$TEST_TMP/date.err"
  status=$?
  assert_ne "0" "$status" "date失敗の終了コード"
  assert_file_missing "$FIXTURE_REPO/.token-saver/token-reports" "date失敗時の出力ディレクトリ"
  assert_file_missing "$FIXTURE_REPO/.token-saver" "date失敗時に作成した管理ディレクトリ"
}

test_move失敗時に作成した空ディレクトリを残さない() {
  _fixture
  _install_failing_wrapper mv CTS_MV_FAIL
  CTS_MV_FAIL=1 _run_launcher >/dev/null 2>"$TEST_TMP/mv.err"
  status=$?
  assert_ne "0" "$status" "move失敗の終了コード"
  assert_file_missing "$FIXTURE_REPO/.token-saver/token-reports" "move失敗時の出力ディレクトリ"
  assert_file_missing "$FIXTURE_REPO/.token-saver" "move失敗時に作成した管理ディレクトリ"
}

test_atomic配置失敗時に作成した空ディレクトリを残さない() {
  _fixture
  _install_failing_wrapper ln CTS_LN_FAIL
  CTS_LN_FAIL=1 _run_launcher >/dev/null 2>"$TEST_TMP/ln.err"
  status=$?
  assert_ne "0" "$status" "atomic配置失敗の終了コード"
  assert_file_missing "$FIXTURE_REPO/.token-saver/token-reports" "配置失敗時の出力ディレクトリ"
  assert_file_missing "$FIXTURE_REPO/.token-saver" "配置失敗時に作成した管理ディレクトリ"
}
