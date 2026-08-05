#!/usr/bin/env bash
# lib/settings-hooks.py の Codex 所有権predicateを直接検証する。
# Claude側の command ベース互換とは分け、Codex側だけ構造一致を要求する。

HOOKS=""
LEDGER=""
CODEX_COMMAND="'/tmp/my clone/scripts/handoff-check.sh'"

_setup_fixture() {
  mkdir -p "$TEST_TMP/fixture"
  HOOKS="$TEST_TMP/fixture/hooks.json"
  LEDGER="$TEST_TMP/fixture/installed.json"
  python3 - "$HOOKS" "$LEDGER" "${1:-valid}" <<'PY'
import copy
import json
import sys

hooks_path, ledger_path, variant = sys.argv[1:]
command = "'/tmp/my clone/scripts/handoff-check.sh'"
managed = {
    "type": "command",
    "command": command,
    "additionalContextLimit": 10000,
}
group = {"matcher": "startup|clear", "hooks": [managed]}
data = {
    "custom": {"keep": True},
    "hooks": {"SessionStart": [group]},
}

if variant == "stop":
    data["hooks"]["Stop"] = [{"hooks": [{"type": "command", "command": command}]}]
elif variant == "matcher":
    group["matcher"] = "other"
elif variant == "type":
    managed["type"] = "url"
elif variant == "limit":
    managed["additionalContextLimit"] = 9999
elif variant == "missing-limit":
    del managed["additionalContextLimit"]
elif variant == "metadata":
    group["description"] = "利用者が追加したgroup metadata"
elif variant == "duplicate":
    group["hooks"].append(copy.deepcopy(managed))
elif variant == "same-group-user":
    group["hooks"].append({"type": "command", "command": "echo 利用者hook"})
elif variant == "bom":
    group["hooks"].append({"type": "command", "command": "echo 利用者hook"})
elif variant != "valid":
    raise SystemExit("unknown fixture: %s" % variant)

with open(hooks_path, "w", encoding="utf-8-sig" if variant == "bom" else "utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
with open(ledger_path, "w", encoding="utf-8") as handle:
    json.dump({"codex_hooks": [command]}, handle)
    handle.write("\n")
PY
}

_validate_codex() {
  CODEX_VALIDATE_STATUS=0
  python3 "$REPO_ROOT/lib/settings-hooks.py" validate-codex "$HOOKS" \
    --ledger "$LEDGER" >/dev/null 2>&1 || CODEX_VALIDATE_STATUS=$?
}

_remove_codex() {
  CODEX_REMOVE_STATUS=0
  python3 "$REPO_ROOT/lib/settings-hooks.py" remove "$HOOKS" \
    --ledger "$LEDGER" --ledger-key codex_hooks >/dev/null 2>&1 || CODEX_REMOVE_STATUS=$?
}

test_Codexの完全一致predicateだけを受け入れる() {
  _setup_fixture valid
  _validate_codex
  assert_eq "0" "$CODEX_VALIDATE_STATUS" "完全一致Codex predicate"
}

test_Codexの同commandがStopにあれば削除しない() {
  _setup_fixture stop
  cp "$HOOKS" "$TEST_TMP/before.json"
  _remove_codex
  assert_ne "0" "$CODEX_REMOVE_STATUS" "Stop同commandの削除終了コード"
  cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "Stop同commandでhooks.jsonを変更した"
  assert_contains "$(cat "$HOOKS")" "handoff-check.sh" "Stop同commandの残存"
}

test_Codexのmatcher変更は削除しない() {
  _setup_fixture matcher
  cp "$HOOKS" "$TEST_TMP/before.json"
  _remove_codex
  assert_ne "0" "$CODEX_REMOVE_STATUS" "matcher変更の削除終了コード"
  cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "matcher変更でhooks.jsonを変更した"
  assert_contains "$(cat "$HOOKS")" "other" "変更されたmatcherの残存"
}

test_Codexのtype変更は削除しない() {
  _setup_fixture type
  cp "$HOOKS" "$TEST_TMP/before.json"
  _remove_codex
  assert_ne "0" "$CODEX_REMOVE_STATUS" "type変更の削除終了コード"
  cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "type変更でhooks.jsonを変更した"
  assert_contains "$(cat "$HOOKS")" '"url"' "変更されたtypeの残存"
}

test_Codexのlimit変更と欠損は削除しない() {
  local variant
  for variant in limit missing-limit; do
    _setup_fixture "$variant"
    cp "$HOOKS" "$TEST_TMP/before.json"
    _remove_codex
    assert_ne "0" "$CODEX_REMOVE_STATUS" "${variant}の削除終了コード"
    cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "${variant}でhooks.jsonを変更した"
    assert_contains "$(cat "$HOOKS")" "handoff-check.sh" "${variant}のhook残存"
  done
}

test_Codexのgroup_metadata変更は削除しない() {
  _setup_fixture metadata
  cp "$HOOKS" "$TEST_TMP/before.json"
  _remove_codex
  assert_ne "0" "$CODEX_REMOVE_STATUS" "group metadata変更の削除終了コード"
  cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "group metadata変更でhooks.jsonを変更した"
  assert_contains "$(cat "$HOOKS")" "利用者が追加したgroup metadata" "group metadataの残存"
}

test_Codexの完全重複は削除しない() {
  _setup_fixture duplicate
  cp "$HOOKS" "$TEST_TMP/before.json"
  _remove_codex
  assert_ne "0" "$CODEX_REMOVE_STATUS" "完全重複の削除終了コード"
  cmp -s "$TEST_TMP/before.json" "$HOOKS" || _fail "完全重複でhooks.jsonを変更した"
  assert_count 2 "$(cat "$HOOKS")" "additionalContextLimit" "完全重複の残存数"
}

test_Codexの同group別commandはmanagedだけ外す() {
  _setup_fixture same-group-user
  _remove_codex
  assert_eq "0" "$CODEX_REMOVE_STATUS" "同group別commandの削除終了コード"
  assert_not_contains "$(cat "$HOOKS")" "handoff-check.sh" "managed commandの削除"
  assert_contains "$(cat "$HOOKS")" "echo 利用者hook" "同group利用者hookの保持"
}

test_CodexのBOMと空白入りquoted_commandを扱う() {
  _setup_fixture bom
  _remove_codex
  assert_eq "0" "$CODEX_REMOVE_STATUS" "BOM付きquoted commandの削除終了コード"
  first_bytes="$(od -An -tx1 -N3 "$HOOKS" | tr -d ' \n')"
  assert_eq "efbbbf" "$first_bytes" "BOMの保持"
  assert_not_contains "$(cat "$HOOKS")" "handoff-check.sh" "空白入りmanaged commandの削除"
  assert_contains "$(cat "$HOOKS")" "echo 利用者hook" "BOM付き利用者hookの保持"
}
