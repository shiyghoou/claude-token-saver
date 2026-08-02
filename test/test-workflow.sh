#!/usr/bin/env bash
# GitHub Actions のファイル選択契約を検査する。

test_ShellCheck対象がBashスクリプトだけを含む() {
  local workflow selected
  workflow="$(cat "$REPO_ROOT/.github/workflows/test.yml")"
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

  selected="$(git -C "$REPO_ROOT" ls-files -z -- \
    'install.sh' 'uninstall.sh' 'scripts/*.sh' 'scripts/**/*.sh' | tr '\0' '\n')"
  assert_not_contains "$selected" ".py" "ShellCheck対象にPythonを含めない"
  assert_contains "$selected" "scripts/token-report.sh" \
    "新しいlauncherをShellCheck対象に含める"
  assert_contains "$selected" "scripts/lib/paths.sh" \
    "scripts/libのShellCheck対象を維持する"
}
