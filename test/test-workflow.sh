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
