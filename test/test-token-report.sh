#!/usr/bin/env bash
# measure-token-usage.py の契約 fixture。実データや利用者の設定を読まずに、
# 集計の重複排除・期間・分類と共有時の秘匿境界を検証する。

set -u

_fixture() {
  FIXTURE_HOME="$TEST_TMP/home"
  FIXTURE_REPO="$TEST_TMP/repo with a deliberately long name"
  FIXTURE_CONFIG="$TEST_TMP/alternate config"
  FIXTURE_OUT="$TEST_TMP/report.md"
  mkdir -p "$FIXTURE_HOME/.claude/projects" "$FIXTURE_REPO/.git" \
    "$FIXTURE_REPO-sibling" "$FIXTURE_REPO/relative-install"

  python3 - "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_CONFIG" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

home, repo, config = sys.argv[1:]
now = datetime.now(timezone.utc)

def stamp(minutes):
    return (now - timedelta(minutes=minutes)).isoformat().replace("+00:00", "Z")

def usage(inp, create, read, output):
    return {"input_tokens": inp, "cache_creation_input_tokens": create,
            "cache_read_input_tokens": read, "output_tokens": output}

def key(path):
    return "".join(c if c.isalnum() and c.isascii() else "-" for c in path)

project = os.path.join(home, ".claude", "projects", key(repo))
os.makedirs(os.path.join(project, "session", "subagents"), exist_ok=True)
rows = []

# 同じ message.id の thinking/tool_use 行。usage は一度だけ数える。
duplicate_usage = usage(10, 100, 1000, 50)
for block in ({"type": "thinking", "thinking": "秘密の思考 sentinel"},
              {"type": "tool_use", "id": "toolu-read", "name": "Read",
               "input": {"file_path": repo + "/inside-visible.md"}}):
    rows.append({"type": "assistant", "timestamp": stamp(10), "sessionId": "session",
                 "message": {"id": "message-duplicate", "model": "claude-opus-5[1m]",
                             "usage": duplicate_usage, "content": [block]}})

# 別メッセージ。repo内・repo外・兄弟・相対 Read と MCP/Agent 起動を含める。
rows.append({"type": "assistant", "timestamp": stamp(9), "sessionId": "session",
             "message": {"id": "message-main", "model": "claude-sonnet-5",
                         "usage": usage(1, 200, 2000, 30), "content": [
                 {"type": "tool_use", "name": "Read", "input":
                  {"file_path": repo + "/inside-visible.md"}},
                 {"type": "tool_use", "name": "Read", "input":
                  {"file_path": "/outside/SECRET_EXTERNAL_PATH"}},
                 {"type": "tool_use", "name": "Read", "input":
                  {"file_path": repo + "-sibling/SECRET_SIBLING_PATH"}},
                 {"type": "tool_use", "name": "Read", "input":
                  {"file_path": "relative/SECRET_RELATIVE_PATH"}},
                 {"type": "tool_use", "name": "Agent", "input":
                  {"subagent_type": "plot-adversarial-reviewer",
                   "prompt": "秘密の prompt sentinel"}},
                 {"type": "tool_use", "name": "mcp__example_server__ping", "input": {}},
                 {"type": "tool_use", "name": "mcp__unknown_server__run", "input": {}},
                 {"type": "tool_use", "name": "mcp__broken", "input": {}}]}})

# id の無い usage 行。requestId と内容が同じ3行は代替キーで一度だけ数える。
for _ in range(3):
    rows.append({"type": "assistant", "timestamp": stamp(7), "sessionId": "session",
                 "requestId": "request-duplicate",
                 "message": {"model": "claude-sonnet-5", "usage": usage(0, 0, 0, 0),
                             "content": []}})

# toolUseResult の分類値、usage、prompt、content は出力してはいけない。
rows.append({"type": "user", "timestamp": stamp(8), "sessionId": "session",
             "toolUseResult": {"agentType": "plot-adversarial-reviewer",
                               "resolvedModel": "claude-opus-4-8[1m]",
                               "totalTokens": 12345, "usage": usage(5, 300, 3000, 40),
                               "prompt": "秘密の tool result prompt",
                               "content": "秘密の tool result content"},
             "message": {"role": "user", "content": "秘密の本文 sentinel"}})

# 期間外の行。
rows.append({"type": "assistant", "timestamp": stamp(60 * 24 * 30), "sessionId": "old",
             "message": {"id": "message-old", "model": "old-model",
                         "usage": usage(7, 7000, 70000, 700), "content": []}})

with open(os.path.join(project, "session.jsonl"), "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    fh.write('{"type":"assistant","message":{"content":"not-a-list"}}\n')
    fh.write('{broken jsonl\n')

with open(os.path.join(project, "session", "subagents", "a.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"type": "assistant", "timestamp": stamp(8),
                         "message": {"id": "subagent-only", "model": "sub-model",
                                     "usage": usage(9, 900, 9000, 90),
                                     "content": [{"type": "text", "text": "秘密の subagent 本文"}]}},
                         ensure_ascii=False) + "\n")

settings = {
    "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{
        "type": "command", "command": "/bin/secret-hook --token=SECRET_HOOK_TOKEN"}]},
        {"matcher": "Edit", "hooks": [{"type": "command",
         "command": "HOOK_SECRET_ENV=SECRET_ENV_VALUE /bin/edit-hook"}]}]},
    "enabledPlugins": {"disabled-plugin@local": False}}
claude_json = {"mcpServers": {"example-server": {"command": "node",
                                                   "env": {"API_KEY": "SECRET_MCP_ENV"}}}}
os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
with open(os.path.join(home, ".claude", "settings.json"), "w") as fh:
    json.dump(settings, fh)
with open(os.path.join(home, ".claude.json"), "w") as fh:
    json.dump(claude_json, fh)

plugins = os.path.join(home, ".claude", "plugins")
active = os.path.join(plugins, "cache", "local", "active", "1.0")
disabled = os.path.join(plugins, "cache", "local", "disabled", "1.0")
os.makedirs(os.path.join(active, ".claude-plugin"), exist_ok=True)
os.makedirs(disabled, exist_ok=True)
with open(os.path.join(plugins, "installed_plugins.json"), "w") as fh:
    json.dump({"plugins": {"active@local": [{"installPath": active}],
                            "disabled-plugin@local": [{"installPath": disabled}],
                            "relative-plugin@local": [{"installPath": "relative-install"}]}}, fh)
with open(os.path.join(active, ".claude-plugin", "plugin.json"), "w") as fh:
    json.dump({"mcpServers": {"plugin-server": {"command": "node",
                                                  "env": {"TOKEN": "SECRET_PLUGIN_ENV"}},
                             "escaped-server": "../../outside.json"}}, fh)
with open(os.path.join(plugins, "cache", "local", "outside.json"), "w") as fh:
    json.dump({"mcpServers": {"outside-server": {"command": "node"}}}, fh)
with open(os.path.join(disabled, ".mcp.json"), "w") as fh:
    json.dump({"mcpServers": {"disabled-server": {"command": "node"}}}, fh)

# --paths と project-key 照合用の実体。長い空白入りパスを別キーへ複製する。
alt_project = os.path.join(config, "projects", key(repo))
os.makedirs(alt_project, exist_ok=True)
with open(os.path.join(alt_project, "session.jsonl"), "w", encoding="utf-8") as out:
    with open(os.path.join(project, "session.jsonl"), encoding="utf-8") as src:
        out.write(src.read())
PYEOF
  : > "$FIXTURE_REPO/inside-visible.md"
}

_run_report() {
  _fixture
  ( cd "$FIXTURE_REPO" && HOME="$FIXTURE_HOME" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR_OVERRIDE:-}" \
      python3 "$REPO_ROOT/scripts/measure-token-usage.py" --out "$FIXTURE_OUT" \
      --all-projects "$@" )
}

_report() {
  [ -f "$FIXTURE_OUT" ] && sed -n '1,240p' "$FIXTURE_OUT" || true
}

test_同一message_idの重複を一度だけ集計する() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "3,391" "重複排除後の合計"
  assert_contains "$report" "重複排除した行: 1" "重複行数"
}

test_id無し行の重複を代替キーで抑える() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" 'message.id' "代替キーの報告"
  assert_contains "$report" "requestId" "id無し行の識別"
}

test_subagentsの詳細usageを親の合計へ混ぜない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_not_contains "$report" "13,390" "親への二重計上"
  assert_contains "$report" "subagents/" "subagents別枠"
}

test_サブエージェントをagentTypeとresolvedModelで分類する() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "plot-adversarial-reviewer" "agentType"
  assert_contains "$report" "claude-opus-4-8[1m]" "resolvedModel"
  assert_contains "$report" "12,345" "toolUseResult totalTokens"
}

test_期間外の行を除外し_days_0で全期間を読む() {
  _run_report --days 1 >/dev/null 2>&1
  recent="$(_report)"
  assert_not_contains "$recent" "77,707" "期間外の合計"
  _run_report --days 0 >/dev/null 2>&1
  all_time="$(_report)"
  assert_contains "$all_time" "81,098" "全期間の合計"
}

test_本文_prompt_tool結果_env_認証情報を出力しない() {
  _run_report --days 0 >/dev/null 2>&1
  report="$(_report)"
  for secret in "秘密の思考 sentinel" "秘密の prompt sentinel" "秘密の tool result prompt" \
    "秘密の tool result content" "秘密の本文 sentinel" "SECRET_HOOK_TOKEN" \
    "SECRET_ENV_VALUE" "SECRET_MCP_ENV" "SECRET_PLUGIN_ENV"; do
    assert_not_contains "$report" "$secret" "秘匿値 $secret"
  done
}

test_MCP設定と実利用の差分を報告する() {
  _run_report --days 0 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "example-server" "設定MCP"
  assert_contains "$report" "plugin-server" "プラグインMCP"
  assert_contains "$report" "unknown_server" "未検出MCP"
  assert_not_contains "$report" "disabled-server" "無効プラグイン"
  assert_not_contains "$report" "outside-server" "プラグイン外参照"
}

test_repo外のReadパスを隠す() {
  _run_report --days 0 --paths >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "inside-visible.md" "repo内Read"
  assert_contains "$report" "(repo外)" "repo外Read"
  assert_not_contains "$report" "SECRET_EXTERNAL_PATH" "外部絶対パス"
  assert_not_contains "$report" "SECRET_SIBLING_PATH" "兄弟パス"
  assert_not_contains "$report" "SECRET_RELATIVE_PATH" "相対パス"
}

test_CLAUDE_CONFIG_DIRと長い空白入りプロジェクトパスを扱う() {
  CLAUDE_CONFIG_DIR_OVERRIDE="$TEST_TMP/alternate config"
  _run_report --days 0 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "計測条件" "CLAUDE_CONFIG_DIR"
  assert_not_contains "$report" "フォールバック" "空白入りプロジェクトキー"
}

test_壊れたJSONLとcontent型違いでもトレースバックを出さない() {
  _run_report --days 1 >/dev/null 2>"$TEST_TMP/engine.err"
  status=$?
  assert_eq "0" "$status" "壊れた入力でも終了コード"
  err="$(cat "$TEST_TMP/engine.err")"
  assert_not_contains "$err" "Traceback" "トレースバック"
}

test_入力と設定とリポジトリを変更しない() {
  _fixture
  before="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  ( cd "$FIXTURE_REPO" && HOME="$FIXTURE_HOME" python3 "$REPO_ROOT/scripts/measure-token-usage.py" \
      --out "$FIXTURE_OUT" --all-projects --days 0 ) >/dev/null 2>"$TEST_TMP/engine.err"
  after="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  assert_eq "$before" "$after" "入力・設定・リポジトリの指紋"
  pyc="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" -name '*.pyc' -o -name '__pycache__' 2>/dev/null)"
  assert_empty "$pyc" "pyc残留"
}
