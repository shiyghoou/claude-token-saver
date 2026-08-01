#!/usr/bin/env bash
# scripts/lib/paths.sh の契約テスト。
#
# ここだけはパスのリテラルを直書きする。paths.sh から期待値を導出すると
# 実装とテストが同じ定義を参照するだけになり、パスがまるごと間違っていても
# 両者が一致して緑になる。test/run.sh の静的ゲートも、この理由で test/ を
# 対象外にしている。

_load_paths() {
  # shellcheck disable=SC1090
  . "$REPO_ROOT/scripts/lib/paths.sh"
}

test_新パスの相対パスを返す() {
  _load_paths
  assert_eq ".token-saver" "$(cts_base_rel)" "cts_base_rel"
  assert_eq ".token-saver/handoff" "$(cts_handoff_rel)" "cts_handoff_rel"
  assert_eq ".token-saver/installed.json" "$(cts_ledger_rel)" "cts_ledger_rel"
  assert_eq ".token-saver/token-report.sh" "$(cts_token_report_rel)" "cts_token_report_rel"
}

test_旧パスの相対パスを返す() {
  _load_paths
  assert_eq ".claude/.handoff" "$(cts_legacy_handoff_rel)" "cts_legacy_handoff_rel"
  assert_eq ".claude/.token-saver" "$(cts_legacy_state_rel)" "cts_legacy_state_rel"
  assert_eq ".claude/.token-saver/installed.json" "$(cts_legacy_ledger_rel)" \
    "cts_legacy_ledger_rel"
}

test_新パスが_claude_配下を指さない() {
  _load_paths
  assert_not_contains "$(cts_base_rel)" ".claude" "cts_base_rel"
  assert_not_contains "$(cts_handoff_rel)" ".claude" "cts_handoff_rel"
  assert_not_contains "$(cts_ledger_rel)" ".claude" "cts_ledger_rel"
}

test_末尾に改行を付けない() {
  _load_paths
  local out
  out="$(printf '%sX' "$(cts_base_rel)")"
  assert_eq ".token-saverX" "$out" "改行が混ざっていない"
}

test_新パスは相対パスである() {
  _load_paths
  case "$(cts_base_rel)" in
    /*) _fail "cts_base_rel が絶対パスを返している: $(cts_base_rel)" ;;
  esac
  assert_ne "" "$(cts_base_rel)" "cts_base_rel が空でない"
}

test_フックの置き場所が新パスを組み立てる() {
  # common.sh は paths.sh を使って絶対パスを組み立てる。
  # cwd を渡さない場合は $PWD 基準になる。
  # shellcheck disable=SC1090
  . "$REPO_ROOT/scripts/lib/common.sh"
  assert_eq "$PWD/.token-saver/handoff" "$(cts_handoff_dir)" "cts_handoff_dir"
  assert_eq "$PWD/.token-saver" "$(cts_state_dir)" "cts_state_dir"
}

# SKILL.md はモデルへの指示であり、書き込み先を選ぶのはこの文書である。
# test/run.sh の静的ゲートは skills/** を対象外にしている（Markdown にはコメント
# 構文が無く、行頭 # の免除が効かないため、パス直書きを許すと散文が書けなくなる）。
# その結果 SKILL.md の書き込み先はゲートにもテストにも縛られていない。
# cts_handoff_rel() を変えても SKILL.md が追随しなければ、モデルは旧い場所へ
# 書き続け、フックは新しい場所しか読まない。エラーにはならず、引き継ぎが
# 静かに二度と注入されなくなるだけである。
#
# ここで paths.sh から期待値を導出するのは「二層問題」（同じ定義をテストと実装の
# 両方に置くと、まるごと間違っていても両者が一致して緑になる）には当たらない。
# 値そのものの契約は test_新パスの相対パスを返す がリテラルで別途ピン留めして
# いるため、このテストが守るのは値ではなく「SKILL.md が paths.sh の値に追随して
# いるか」という一致性である。paths.sh 側の値が丸ごと間違っていれば、上のリテラル
# 契約テストが単独で赤くなる。
#
# 緩い assert_contains だけでは「保存先とファイル名」節の書き込み指示行と、
# その下の「例:」行のどちらが一致していても緑になる。指示行だけを壊して
# 例を残す改変（レビューで実際に確認済み）でもこの緩い形は素通りするため、
# 指示行そのもの（コードフェンス内のパステンプレート）に絞った厳しい形と、
# 旧パスが指示として残っていないことの否定形を両方置く。
test_SKILL_MDの保存先がpathsshと一致する() {
  _load_paths
  local skill_md
  skill_md="$(cat "$REPO_ROOT/skills/session-handoff/SKILL.md")"
  assert_contains "$skill_md" "$(cts_handoff_rel)/pending" \
    "SKILL.md の保存先が cts_handoff_rel() と一致する"
  assert_contains "$skill_md" \
    "<リポジトリルート>/$(cts_handoff_rel)/pending/<YYYY-MM-DD>" \
    "SKILL.md の書き込み指示行そのものが cts_handoff_rel() と一致する"
  assert_not_contains "$skill_md" "$(cts_legacy_handoff_rel)/pending" \
    "SKILL.md が旧パスへの書き込みを指示していない"
}
