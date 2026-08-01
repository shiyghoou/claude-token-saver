#!/usr/bin/env bash
# token-report の利用導線が launcher / README / 設計書 / SKILL で一致することを検証する。

set -u

_skill_path() {
  printf '%s' "$REPO_ROOT/skills/token-report/SKILL.md"
}

_readme() {
  sed -n '1,260p' "$REPO_ROOT/README.md"
}

_design_token_report_section() {
  awk '
    /^### 5\.2 / { in_section=1 }
    /^### 5\.3 / { in_section=0 }
    in_section { print }
  ' "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_skill() {
  sed -n '1,260p' "$(_skill_path)"
}

test_token_report_SKILLがlauncherと保存先を案内する() {
  assert_file_exists "$(_skill_path)"
  skill="$(_skill)"
  assert_contains "$skill" "./scripts/token-report.sh" "skill launcher"
  assert_contains "$skill" "./scripts/token-report.sh --days 30" "skill days example"
  assert_contains "$skill" "./scripts/token-report.sh --days 0 --all-projects" "skill all-projects example"
  assert_contains "$skill" ".token-saver/token-reports/" "skill 保存先"
  assert_contains "$skill" "scripts/measure-token-usage.py" "skill engine"
}

test_token_report_SKILLが設定自動変更を指示しない() {
  assert_file_exists "$(_skill_path)"
  skill="$(_skill)"
  assert_not_contains "$skill" "settings.local.json" "skill settings.local.json"
  assert_not_contains "$skill" "フックを追加" "skill フック追加"
  assert_not_contains "$skill" "自動で書き換" "skill 自動変更"
  assert_not_contains "$skill" "勝手に書き換" "skill 勝手に変更"
}

test_READMEがtoken_reportを実装済みと案内する() {
  readme="$(_readme)"
  assert_contains "$readme" "| 計測（token-report） | **実装済み** |" "README 状態表"
  assert_contains "$readme" "./scripts/token-report.sh" "README launcher"
  assert_contains "$readme" ".token-saver/token-reports/" "README 保存先"
  assert_not_contains "$readme" "| 計測（token-report） | 未実装" "README token-report 未実装"
}

test_設計書の段階2がtoken_reportのCLIと限界を案内する() {
  section="$(_design_token_report_section)"
  assert_contains "$section" "scripts/measure-token-usage.py" "設計書 engine"
  assert_contains "$section" "scripts/token-report.sh" "設計書 launcher"
  assert_contains "$section" ".token-saver/token-reports/" "設計書 保存先"
  assert_contains "$section" "cache_read_input_tokens" "設計書 cache_read"
  assert_contains "$section" "画像" "設計書 画像"
  assert_contains "$section" "MCP" "設計書 MCP"
}

test_PAWARS固有のIssueと提出先を新規文書に残さない() {
  skill="$(_skill)"
  readme="$(_readme)"
  section="$(_design_token_report_section)"
  combined="${skill}
${readme}
${section}"
  assert_not_contains "$combined" "PAWARS" "PAWARS 漏れ"
  assert_not_contains "$combined" "Issue #" "Issue 漏れ"
  assert_not_contains "$combined" "PR #" "PR 漏れ"
  assert_not_contains "$combined" "提出先" "提出先 漏れ"
}
