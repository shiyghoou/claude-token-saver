#!/usr/bin/env bash
# delegation-policy スキルの読み込み条件と判断契約を検証する。

set -u

SKILL="$REPO_ROOT/skills/delegation-policy/SKILL.md"

_skill_text() {
  cat "$SKILL"
}

test_frontmatter名と必要時の読み込み条件を持つ() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "name: delegation-policy" "frontmatter name"
  assert_contains "$body" "description: Use when deciding whether a heavy investigation, implementation, or review should be delegated or parallelized, or which capability tier should own a bounded subtask." "on-demand description"
}

test_非コスト理由を先に判断する() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "並列化" "並列化"
  assert_contains "$body" "ツール制限" "ツール制限"
  assert_contains "$body" "専門知識" "専門知識"
  assert_contains "$body" "独立した敵対的レビュー" "独立レビュー"
}

test_作業の重さと残りの会話期間を判断する() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "作業の重さ" "作業の重さ"
  assert_contains "$body" "残りの会話期間" "会話期間"
  assert_contains "$body" "次のターンで" "直後に切る場合"
}

test_起動と統合の固定費を判断する() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "起動" "起動費"
  assert_contains "$body" "指示の受け渡し" "指示の受け渡し"
  assert_contains "$body" "結果の読解・統合" "統合費"
  assert_contains "$body" "固定費" "固定費"
}

test_起動した結果を必ず回収する() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "必ず回収" "結果回収"
  assert_contains "$body" "完了条件" "完了条件"
  assert_contains "$body" "回収方法" "回収方法"
}

test_能力帯を役割で選ぶ() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "高能力" "高能力"
  assert_contains "$body" "創作" "創作"
  assert_contains "$body" "設計" "設計"
  assert_contains "$body" "矛盾発見" "矛盾発見"
  assert_contains "$body" "敵対的レビュー" "敵対的レビュー"
  assert_contains "$body" "軽量" "軽量"
  assert_contains "$body" "機械的な検索" "機械的検索"
  assert_contains "$body" "形式確認" "形式確認"
  assert_contains "$body" "限定されたテスト実行" "限定テスト"
}

test_段階4を疎結合の参考情報に限定する() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "参考情報" "段階4との関係"
  assert_contains "$body" ".token-saver/calibration/latest.json" "snapshot非依存"
  assert_contains "$body" "snapshot のJSON構造を解析しない" "schema非依存"
  assert_contains "$body" "自動選択しない" "自動選択禁止"
  assert_contains "$body" "設定、フック、MCP、エージェント設定を変更しない" "自動変更禁止"
}

test_数値とモデル名を普遍化しない() {
  local body
  body="$(_skill_text)"
  assert_contains "$body" "直接測定していない" "固定費の限界"
  assert_contains "$body" "固定の損益分岐点" "固定閾値禁止"
  assert_contains "$body" "モデル名" "モデル名非固定"
  assert_contains "$body" "価格" "価格非固定"
  assert_contains "$body" "固定トークン数" "トークン数非固定"
}
