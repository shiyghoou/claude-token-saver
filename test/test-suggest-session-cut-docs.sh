#!/usr/bin/env bash
# suggest-session-cut の利用導線が README / session-handoff / 設計書で一致することを検証する。

set -u

SUGGEST_SESSION_CUT_GUIDANCE="引き継ぎを書いてから、手動で新しいセッションへ切り替えることを検討してください。"

_readme() {
  sed -n '1,320p' "$REPO_ROOT/README.md"
}

_skill() {
  sed -n '1,240p' "$REPO_ROOT/skills/session-handoff/SKILL.md"
}

_design() {
  sed -n '1,580p' "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_design_suggest_section() {
  awk '
    /^### 5\.3 / { in_section=1 }
    /^### 5\.4 / { in_section=0 }
    in_section { print }
  ' "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md"
}

_assert_config_contract() {
  local body="$1" label="$2"
  assert_contains "$body" '`message.usage.cache_read_input_tokens`' "$label measurement key"
  assert_contains "$body" ".claude/token-saver.json" "$label config path"
  assert_contains "$body" '"suggest_session_cut"' "$label config parent key"
  assert_contains "$body" "CTS_SESSION_CUT_INITIAL_CACHE_READ" "$label initial env"
  assert_contains "$body" "CTS_SESSION_CUT_INCREMENT_CACHE_READ" "$label increment env"
  assert_contains "$body" "CTS_SESSION_CUT_RETENTION_DAYS" "$label retention env"
  assert_contains "$body" "CTS_SESSION_CUT_LOG_MAX_BYTES" "$label log bytes env"
  assert_contains "$body" "CTS_SESSION_CUT_LOG_BACKUPS" "$label log backups env"
  assert_contains "$body" '"initial_cache_read": 30000000' "$label initial default"
  assert_contains "$body" '"increment_cache_read": 30000000' "$label increment default"
  assert_contains "$body" '"retention_days": 7' "$label retention default"
  assert_contains "$body" '"log_max_bytes": 1048576' "$label log bytes default"
  assert_contains "$body" '"log_backups": 5' "$label log backups default"
  assert_contains "$body" '`log_backups` は 0 以上 1000 以下' "$label log backups upper bound"
  assert_contains "$body" ".token-saver/session-cut" "$label state path"
  assert_contains "$body" ".cache" "$label cache file"
  assert_contains "$body" ".marker" "$label marker file"
  assert_contains "$body" "events.log" "$label event log"
  assert_contains "$body" "状態ディレクトリへ \`cd -P\`" "$label physical state cwd"
  assert_contains "$body" "owner PID" "$label lock owner"
  assert_contains "$body" "10分以上古い無効lockだけを回収する" "$label stale lock policy"
  assert_contains "$body" "移植元の実測由来" "$label imported defaults"
  assert_contains "$body" "他プロジェクトへ自動適合する保証はない" "$label no auto fit"
  assert_contains "$body" \
    "設定ファイルが無い、または読めない場合は各設定値を、個別値が不正な場合はその値だけを既定値へ戻す。" \
    "$label config fallback"
  assert_contains "$body" \
    '入力・トランスクリプト・状態を判定できない、または読み書きに失敗した場合は fail-closed とし、無出力・標準エラー空・終了コード `0` で抜ける。' \
    "$label fail-closed"
  assert_contains "$body" '`/clear` は自動実行しません' "$label manual clear"
  assert_contains "$body" "$SUGGEST_SESSION_CUT_GUIDANCE" "$label exact manual session switch"
}

test_READMEがsuggest_session_cutを実装済みと案内する() {
  local readme
  readme="$(_readme)"
  assert_contains "$readme" "| セッション切り提案（suggest-session-cut） | **実装済み** |" \
    "README 状態表"
  assert_contains "$readme" "| キャリブレーションと診断（calibrate） | **実装済み** |" \
    "README 状態表"
  assert_not_contains "$readme" "| セッション切り提案（suggest-session-cut） | 未実装" \
    "README suggest-session-cut 未実装"
}

test_READMEと設計書が設定キー既定値状態パスを共有する() {
  _assert_config_contract "$(_readme)" "README"
  _assert_config_contract "$(_design_suggest_section)" "設計書 5.3"
}

test_session_handoff_SKILLが提案後の手動切替手順を案内する() {
  local skill
  skill="$(_skill)"
  assert_contains "$skill" "Stop フックが「セッションを切ることを推奨します」と出した" \
    "SKILL Stop trigger"
  assert_contains "$skill" "$SUGGEST_SESSION_CUT_GUIDANCE" \
    "SKILL manual switch"
  assert_contains "$skill" "書いたら、切ることをユーザーへ提案する。" \
    "SKILL propose switching"
  assert_contains "$skill" '`/clear` はユーザーの操作' \
    "SKILL clear ownership"
  _assert_config_contract "$skill" "SKILL"
}

test_設計書がinstall契約と実装フェーズを現在状態へ追随させる() {
  local design
  design="$(_design)"
  assert_contains "$design" '`Stop` に `suggest-session-cut.sh` を登録する。' \
    "設計書 install Stop"
  assert_contains "$design" "| 3 | 切り提案フック移植＋一般化＋繰り越し修正 | 自動提案が動く（既定値＝移植元の実測由来） |" \
    "設計書 段階3"
  assert_contains "$design" "| 4 | キャリブレーションと診断 | 実測に合った閾値と改善提案が出る（段階2） |" \
    "設計書 段階4"
  assert_contains "$design" "段階1〜5は本リポジトリで実装済みである。" \
    "設計書 実装状態"
  assert_not_contains "$design" "Stop フックは段階3の成果物であり、それまでは登録されない" \
    "設計書 future install wording"
  assert_contains "$design" "suggest-session-cut-json.awk" "設計書 payload JSON validator"
  assert_contains "$design" "suggest-session-cut-config.awk" "設計書 config JSON validator"
  assert_contains "$design" "Stop payload 全体を末尾まで完全な JSON として検証する" \
    "設計書 payload complete JSON validation"
  assert_contains "$design" "lock" "設計書 state lock"
  assert_contains "$design" "symlink" "設計書 symlink fail-closed"
  assert_contains "$design" "実在する数値ログ世代だけを列挙する" "設計書 bounded log generation enumeration"
}

test_READMEがtoken_report節でcalibrateの安全境界を案内する() {
  local readme
  readme="$(_readme)"
  assert_contains "$readme" "./.token-saver/token-report.sh --calibrate" \
    "README token-report calibration command"
  assert_contains "$readme" "./.token-saver/token-calibrate.sh --apply" \
    "README token-report explicit apply command"
  assert_contains "$readme" "明示的に" "README token-report apply boundary"
  assert_not_contains "$readme" "calibrate は未実装" "README token-report stale wording"
}
