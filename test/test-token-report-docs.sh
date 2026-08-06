#!/usr/bin/env bash
# token-report の利用導線が launcher / README / 設計書 / SKILL で一致することを検証する。

set -u

_skill_path() {
  printf '%s' "$REPO_ROOT/skills/token-report/SKILL.md"
}

_readme() {
  # calibrate 節の「概算診断」境界まで含める（320 行だと直前で切れて契約検査が偽陰性になる）
  sed -n '1,340p' "$REPO_ROOT/README.md"
}

_design_token_report_section() {
  awk '
    /^### 5\.2 / { in_section=1 }
    /^### 5\.3 / { in_section=0 }
    in_section { print }
  ' "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_design_calibration_section() {
  awk '
    /^### 5\.5 / { in_section=1 }
    /^## 6\. / { in_section=0 }
    in_section { print }
  ' "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_skill() {
  sed -n '1,260p' "$(_skill_path)"
}

_wave5_design() {
  sed -n '1,220p' \
    "$REPO_ROOT/docs/superpowers/specs/2026-08-02-wave5-token-report-design.md"
}

_doc_paths() {
  printf '%s\n' \
    "$REPO_ROOT/README.md" \
    "$REPO_ROOT/skills/token-report/SKILL.md" \
    "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_assert_shared_contract() {
  doc_path="$1"
  case "$doc_path" in
    "$REPO_ROOT/README.md")
      body="$(_readme)"
      ;;
    "$REPO_ROOT/skills/token-report/SKILL.md")
      body="$(_skill)"
      ;;
    "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md")
      body="$(_design_token_report_section)"
      ;;
    *)
      _fail "未知の文書: $doc_path"
      ;;
  esac
  label="$(basename "$doc_path")"

  assert_contains "$body" "./.token-saver/token-report.sh" "$label launcher"
  assert_contains "$body" ".token-saver/token-reports/" "$label 保存先"
  assert_contains "$body" "--days" "$label days"
  assert_contains "$body" "--out" "$label out"
  assert_contains "$body" "--top" "$label top"
  assert_contains "$body" "--all-projects" "$label all-projects"
  assert_contains "$body" "--paths" "$label paths"
  assert_contains "$body" "cache_read_input_tokens" "$label cache_read"
  assert_contains "$body" "画像" "$label image"
  assert_contains "$body" "MCP" "$label MCP"
  assert_contains "$body" "読み取り専用" "$label read-only"
  assert_contains "$body" "自動変更しない" "$label no auto settings change"
  assert_contains "$body" "Stop フック" "$label stop hook scope"
  assert_contains "$body" "calibrate" "$label calibrate scope"
}

test_token_report_SKILLがlauncherと保存先を案内する() {
  assert_file_exists "$(_skill_path)"
  skill="$(_skill)"
  assert_contains "$skill" "./.token-saver/token-report.sh" "skill launcher"
  assert_contains "$skill" "./.token-saver/token-report.sh --days 30" "skill days example"
  assert_contains "$skill" "./.token-saver/token-report.sh --days 0 --all-projects" "skill all-projects example"
  assert_contains "$skill" ".token-saver/token-reports/" "skill 保存先"
  assert_contains "$skill" "scripts/measure-token-usage.py" "skill engine"
}

test_token_report_SKILLが有効なfrontmatterを持つ() {
  python3 - "$(_skill_path)" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()
if not lines or lines[0] != "---":
    raise SystemExit("frontmatter の開始区切りが無い")
try:
    end = lines.index("---", 1)
except ValueError:
    raise SystemExit("frontmatter の終了区切りが無い")
values = {}
for line in lines[1:end]:
    if ":" not in line:
        raise SystemExit("frontmatter が key: value 形式でない")
    key, value = line.split(":", 1)
    key = key.strip()
    value = value.strip()
    if not key or not value or key in values:
        raise SystemExit("frontmatter の key/value が不正である")
    values[key] = value
if set(values) != {"name", "description"}:
    raise SystemExit("frontmatter は name/description だけを持つ必要がある")
if values["name"] != "token-report":
    raise SystemExit("frontmatter name が token-report でない")
PYEOF
  assert_eq "0" "$?" "SKILL frontmatter"
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
  assert_contains "$readme" "./.token-saver/token-report.sh" "README launcher"
  assert_contains "$readme" ".token-saver/token-reports/" "README 保存先"
  assert_not_contains "$readme" "| 計測（token-report） | 未実装" "README token-report 未実装"
}

test_画像消費を現在未計測と全利用文書が明記する() {
  expected="画像の消費は現在の計測エンジンでは未計測である"
  readme="$(sed -n '1,360p' "$REPO_ROOT/README.md")"
  skill="$(_skill)"
  design="$(_design_token_report_section)"
  wave5="$(_wave5_design)"
  assert_contains "$readme" "$expected" "README image semantics"
  assert_contains "$skill" "$expected" "SKILL image semantics"
  assert_contains "$design" "$expected" "基本設計 image semantics"
  assert_contains "$wave5" "$expected" "Wave5設計 image semantics"
  assert_not_contains "$readme$skill$design$wave5" "画像の消費は寸法からの概算" \
    "未実装の画像概算を実装済みと誤認させない"
}

_assert_calibrate_contract() {
  local body="$1" label="$2"
  assert_contains "$body" "./.token-saver/token-report.sh --calibrate" "$label 計測導線"
  assert_contains "$body" "./.token-saver/token-calibrate.sh --apply" "$label 明示適用導線"
  assert_contains "$body" "snapshot" "$label snapshot"
  assert_contains "$body" "実測" "$label measured"
  assert_contains "$body" "概算" "$label estimated"
  assert_contains "$body" "画像の消費は現在の計測エンジンでは未計測である" "$label image limit"
  assert_contains "$body" ".claude/token-saver.json" "$label config path"
  assert_contains "$body" "自動" "$label automatic boundary"
}

test_calibrateの導線と安全境界を全利用文書で一致させる() {
  _assert_calibrate_contract "$(_readme)" "README"
  _assert_calibrate_contract "$(_skill)" "SKILL"
  _assert_calibrate_contract "$(_design_calibration_section)" "DESIGN"
}

test_token_reportの共有契約がREADME_SKILL_設計書で一致する() {
  while IFS= read -r doc_path; do
    _assert_shared_contract "$doc_path"
  done <<EOF
$(_doc_paths)
EOF
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

test_固定コスト未測定とtotalTokens主指標を文書から除く() {
  readme="$(cat "$REPO_ROOT/README.md")"
  skill="$(_skill)"
  design="$(_design_token_report_section)"
  combined="${readme}
${skill}
${design}"
  assert_not_contains "$combined" "直接測定していない" "未測定文言除去"
  assert_not_contains "$combined" "toolUseResult.totalTokens" "totalTokens 主指標除去"
  assert_contains "$readme" "message.usage" "README sub 実測"
  assert_contains "$skill" "起動固定コスト" "SKILL 固定コスト"
  assert_contains "$design" "完全母集団ではない" "設計のカバレッジ限界"
}
