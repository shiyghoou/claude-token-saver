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
