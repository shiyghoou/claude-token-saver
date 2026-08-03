#!/usr/bin/env bash
# Python 3.6互換性の対象スモークテスト。

test_Python_3_6互換性スモーク() {
  python3 -B "$REPO_ROOT/test/python-compatibility.py" >"$TEST_TMP/python-compatibility.out" 2>"$TEST_TMP/python-compatibility.err"
  local status=$?
  assert_eq "0" "$status" "Python互換性スモークの終了コード"
}

test_Python_3_6キャリブレーションCLI境界() {
  python3 -B "$REPO_ROOT/test/python-compatibility.py" >"$TEST_TMP/python-compatibility-cli.out" 2>"$TEST_TMP/python-compatibility-cli.err"
  local status=$?
  assert_eq "0" "$status" "キャリブレーションCLIの終了コード"
  assert_contains "$(cat "$TEST_TMP/python-compatibility-cli.out")" \
    "Python互換性キャリブレーションCLI: PASS" "キャリブレーションCLI検証"
}
