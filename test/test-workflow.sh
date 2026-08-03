#!/usr/bin/env bash
# GitHub Actions のファイル選択契約を検査する。

test_ShellCheck対象がBashスクリプトだけを含む() {
  local workflow shellcheck_line pathspecs unexpected_pathspecs selected
  if ! workflow="$(cat "$REPO_ROOT/.github/workflows/test.yml")"; then
    _fail "test.ymlの読み込みに失敗した"
  fi
  assert_contains "$workflow" \
    "git ls-files -z -- 'install.sh' 'uninstall.sh' 'scripts/*.sh' 'scripts/**/*.sh'" \
    "ShellCheck対象のpathspec"
  assert_not_contains "$workflow" \
    "git ls-files -z -- 'install.sh' 'uninstall.sh' 'scripts/' |" \
    "ShellCheck対象にscripts全体を渡さない"
  assert_not_contains "$workflow" "'scripts/'" \
    "ShellCheck対象にscriptsディレクトリ全体を渡さない"
  assert_count 1 "$workflow" "shellcheck --shell=bash --severity=error" \
    "対象ファイルを検査するShellCheck呼び出し数"

  if ! shellcheck_line="$(printf '%s\n' "$workflow" |
    sed -n "/git ls-files -z -- 'install.sh'/,/xargs -0 shellcheck --shell=bash --severity=error/p" |
    tr '\n' ' ')"; then
    _fail "ShellCheck対象コマンドの抽出に失敗した"
  fi
  if ! pathspecs="$(printf '%s\n' "$shellcheck_line" |
    sed -e 's/.*git ls-files -z -- //' -e 's/ |.*xargs.*//')"; then
    _fail "ShellCheck対象のpathspec抽出に失敗した"
  fi
  if ! unexpected_pathspecs="$(printf '%s\n' "$pathspecs" |
    tr -s '[:space:]' '\n' |
    while IFS= read -r pathspec; do
      case "$pathspec" in
        "'install.sh'"|"'uninstall.sh'"|"'scripts/*.sh'"|"'scripts/**/*.sh'"|"") ;;
        *) printf '%s\n' "$pathspec" ;
      esac
    done)"; then
    _fail "ShellCheck対象の許可外pathspec検査に失敗した"
  fi
  assert_empty "$unexpected_pathspecs" \
    "ShellCheck対象に許可外のpathspecを追加しない"

  if ! selected="$(git -C "$REPO_ROOT" ls-files -z -- \
    'install.sh' 'uninstall.sh' 'scripts/*.sh' 'scripts/**/*.sh' | tr '\0' '\n')"; then
    _fail "ShellCheck対象ファイルの選択に失敗した"
  fi
  assert_not_contains "$selected" ".py" "ShellCheck対象にPythonを含めない"
  assert_contains "$selected" "scripts/token-report.sh" \
    "新しいlauncherをShellCheck対象に含める"
  assert_contains "$selected" "scripts/lib/paths.sh" \
    "scripts/libのShellCheck対象を維持する"
}

_python_compatibility_job() {
  awk '
    /^  python-compatibility:$/ { inside = 1 }
    inside && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != "  python-compatibility:" { exit }
    inside { print }
  ' "$REPO_ROOT/.github/workflows/test.yml"
}

_python_compatibility_run_block() {
  awk '
    /^  python-compatibility:$/ { inside = 1 }
    inside && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != "  python-compatibility:" { exit }
    inside && $0 ~ /^        run: \|[[:space:]]*$/ { run = 1; next }
    run && $0 ~ /^          / { sub(/^          /, ""); print; next }
    run { exit }
  ' "$REPO_ROOT/.github/workflows/test.yml"
}

_python_compatibility_run_commands() {
  _python_compatibility_run_block | awk '!/^[[:space:]]*#/'
}

_run_python_compatibility_smoke_with_fake_docker() {
  local run_block fixture fake_bin script docker_log status docker_args
  if ! run_block="$(_python_compatibility_run_block)"; then
    _fail "python-compatibility run blockの抽出に失敗した"
  fi

  fixture="$TEST_TMP/python-compatibility-workflow"
  fake_bin="$fixture/bin"
  script="$fixture/run.sh"
  docker_log="$fixture/docker.args"
  mkdir -p "$fake_bin"
  if ! printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$*" >"$FAKE_DOCKER_LOG"' \
    'exit 73' >"$fake_bin/docker"; then
    _fail "fake dockerの作成に失敗した"
  fi
  chmod +x "$fake_bin/docker"

  if ! printf '%s\n' "$run_block" |
    sed -e 's@${{ github.workspace }}@${TEST_WORKSPACE}@g' \
        -e 's@${{ matrix.image }}@fake-image@g' >"$script"; then
    _fail "GitHub式を実行用fixtureへ置換できない"
  fi

  if PATH="$fake_bin:$PATH" TEST_WORKSPACE="$fixture" FAKE_DOCKER_LOG="$docker_log" \
    bash "$script" >"$fixture/stdout" 2>"$fixture/stderr"; then
    _fail "fake dockerの失敗がrun blockから伝播しなかった"
  else
    status=$?
  fi
  assert_file_exists "$docker_log" "fake dockerが呼ばれた記録"
  docker_args="$(cat "$docker_log")"
  assert_contains "$docker_args" "run --rm" "実run blockがfake dockerを呼ぶ"
  PYTHON_COMPATIBILITY_FAKE_DOCKER_STATUS="$status"
}

test_Python互換性CIがjob内で固定イメージの読み取り専用スモークを実行する() {
  local job run_block run_commands
  if ! job="$(_python_compatibility_job)"; then
    _fail "python-compatibility jobの抽出に失敗した"
  fi
  if ! run_block="$(_python_compatibility_run_block)"; then
    _fail "python-compatibility run blockの抽出に失敗した"
  fi
  if ! run_commands="$(_python_compatibility_run_commands)"; then
    _fail "python-compatibility run blockのコメント除去に失敗した"
  fi

  assert_contains "$job" "python-compatibility:" \
    "Python互換性の独立job"
  assert_contains "$job" "python:3.6.15-slim-buster" \
    "Python 3.6の固定公式イメージ"
  assert_contains "$job" "python:3.8.20-slim-bookworm" \
    "Python 3.8の固定公式イメージ"
  assert_contains "$run_commands" \
    '--mount "type=bind,source=${{ github.workspace }},target=/work,readonly"' \
    "実run blockの読み取り専用マウント"
  assert_contains "$run_commands" "--workdir /work" \
    "コンテナの作業ディレクトリ"
  assert_contains "$run_commands" "docker run --rm" \
    "使い捨てコンテナの実行"
  assert_contains "$run_commands" "python -B test/python-compatibility.py" \
    "Python互換性スモークの実行"
  assert_not_contains "$run_commands" "||" \
    "実run blockでdocker失敗を握り潰さない"
  assert_not_contains "$run_commands" "; true" \
    "docker失敗の直後に成功終了へ変えない"
  assert_not_contains "$run_commands" "set +e" \
    "docker失敗をerrexit無効化で握り潰さない"
  assert_not_contains "$job" "continue-on-error" \
    "python-compatibility jobでcontinue-on-errorを許可しない"
}

test_Python互換性CIのdocker失敗がrun_blockから伝播する() {
  _run_python_compatibility_smoke_with_fake_docker
  assert_eq "73" "$PYTHON_COMPATIBILITY_FAKE_DOCKER_STATUS" \
    "fake docker失敗の伝播終了コード"
}
