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
# 0 token では重複排除を外しても合計が変わらず、件数文言だけのテストに退行するため、
# 合計へ影響する値を使う。
for _ in range(3):
    rows.append({"type": "assistant", "timestamp": stamp(7), "sessionId": "session",
                 "requestId": "request-duplicate",
                 "message": {"model": "claude-sonnet-5", "usage": usage(2, 20, 200, 3),
                             "content": []}})

# toolUseResult の分類値、usage、prompt、content は出力してはいけない。
rows.append({"type": "user", "timestamp": stamp(8), "sessionId": "session",
             "toolUseResult": {"agentType": "plot-adversarial-reviewer",
                               "resolvedModel": "claude-opus-4-8[1m]",
                               "totalTokens": 12345, "usage": usage(5, 300, 3000, 40),
                               "prompt": "秘密の tool result prompt",
                               "content": "秘密の tool result content"},
             "message": {"role": "user", "content": "秘密の本文 sentinel"}})

# --top の一覧制限を検証するための 0 token 補助データ。
rows.append({"type": "assistant", "timestamp": stamp(6), "sessionId": "session",
             "message": {"id": "message-extra", "model": "claude-haiku-5",
                         "usage": usage(0, 0, 0, 0), "content": [
                 {"type": "tool_use", "name": "Read", "input":
                  {"file_path": repo + "/second-visible.md"}},
                 {"type": "tool_use", "name": "Agent", "input":
                  {"subagent_type": "lint-reviewer"}}]}})
rows.append({"type": "user", "timestamp": stamp(5), "sessionId": "session",
             "toolUseResult": {"agentType": "lint-reviewer",
                               "resolvedModel": "claude-sonnet-5",
                               "totalTokens": 0, "usage": usage(0, 0, 0, 0)},
             "message": {"role": "user", "content": "suppressed helper body"}})

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
with open(os.path.join(repo, "relative-install", ".mcp.json"), "w") as fh:
    json.dump({"mcpServers": {"relative-server": {"command": "node"}}}, fh)

# --paths と project-key 照合用の実体。長い空白入りパスを別キーへ複製する。
alt_project = os.path.join(config, "projects", key(repo))
os.makedirs(alt_project, exist_ok=True)
with open(os.path.join(config, "settings.json"), "w") as fh:
    json.dump(settings, fh)
with open(os.path.join(config, "claude.json"), "w") as fh:
    json.dump(claude_json, fh)
with open(os.path.join(alt_project, "session.jsonl"), "w", encoding="utf-8") as out:
    with open(os.path.join(project, "session.jsonl"), encoding="utf-8") as src:
        out.write(src.read())
PYEOF
  : > "$FIXTURE_REPO/inside-visible.md"
  : > "$FIXTURE_REPO/second-visible.md"
}

_execute_report_from() {
  run_dir="$1"
  shift
  ( cd "$run_dir" && HOME="$FIXTURE_HOME" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR_OVERRIDE:-}" \
      python3 -B "$REPO_ROOT/scripts/measure-token-usage.py" --out "$FIXTURE_OUT" "$@" )
}

_execute_report() {
  _execute_report_from "$FIXTURE_REPO" --all-projects "$@"
}

_run_report() {
  _fixture
  _execute_report "$@"
}

_report() {
  [ -f "$FIXTURE_OUT" ] && sed -n '1,240p' "$FIXTURE_OUT" || true
}

_add_unrelated_project() {
  python3 - "$FIXTURE_HOME" <<'PYEOF'
import json
import os
import sys
from datetime import datetime, timezone

home = sys.argv[1]

def key(path):
    return "".join(c if c.isalnum() and c.isascii() else "-" for c in path)

project = os.path.join(home, ".claude", "projects", key("/tmp/unrelated-project"))
os.makedirs(project, exist_ok=True)
row = {
    "type": "assistant",
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "sessionId": "other",
    "message": {
        "id": "other-message",
        "model": "other-project-model",
        "usage": {
            "input_tokens": 2,
            "cache_creation_input_tokens": 20,
            "cache_read_input_tokens": 200,
            "output_tokens": 2,
        },
        "content": [],
    },
}
with open(os.path.join(project, "other.jsonl"), "w", encoding="utf-8") as fh:
    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
PYEOF
}

test_同一message_idの重複を一度だけ集計する() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "3,616" "重複排除後の合計"
  assert_contains "$report" "重複排除した行: 1" "重複行数"
}

test_id無し行の重複を代替キーで抑える() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "main 合計: **3,616**" "代替キー込みの正確な合計"
  assert_contains "$report" 'message.id` を持たない usage 行: 3' "id無し行数"
  assert_contains "$report" "代替キーで重複排除した行: 2" "代替キーの重複数"
}

test_subagentsの詳細usageを親の合計へ混ぜない() {
  _run_report --days 1 >/dev/null 2>&1
  report="$(_report)"
  assert_not_contains "$report" "13,615" "親への二重計上"
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
  assert_contains "$all_time" "81,323" "全期間の合計"
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
  assert_not_contains "$report" "relative-server" "相対installPath"
  assert_not_contains "$report" "mcp__broken" "壊れたMCPツール名"
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

test_top_は一覧ごとの最大行数を制限する() {
  _run_report --days 1 --top 1 --paths >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "claude-sonnet-5" "model先頭"
  assert_not_contains "$report" "claude-opus-5[1m]" "model制限"
  assert_contains "$report" "plot-adversarial-reviewer" "subagent先頭"
  assert_not_contains "$report" "lint-reviewer" "subagent制限"
  assert_contains "$report" "example-server" "MCP先頭"
  assert_not_contains "$report" "plugin-server" "MCP制限"
  assert_contains "$report" "(repo外)" "Read先頭"
  assert_not_contains "$report" "inside-visible.md" "Read制限"
}

test_top_0は拒否する() {
  _fixture
  _execute_report --days 1 --top 0 >/dev/null 2>"$TEST_TMP/top.err"
  status=$?
  err="$(cat "$TEST_TMP/top.err")"
  assert_eq "2" "$status" "top下限"
  assert_contains "$err" "--top には 1 以上を指定してください" "topエラー文言"
}

test_CLAUDE_CONFIG_DIRと長い空白入りプロジェクトパスを扱う() {
  _fixture
  # HOME 側を読んで通る実装を防ぐ。alternate config 側だけを残しても、
  # 既知の全期間合計を読めなければこのテストは通らない。
  rm -rf "$FIXTURE_HOME/.claude/projects"
  CLAUDE_CONFIG_DIR_OVERRIDE="$FIXTURE_CONFIG" _execute_report --days 0 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "81,323" "CLAUDE_CONFIG_DIRの実データ"
  assert_not_contains "$report" "フォールバック" "空白入りプロジェクトキー"
}

test_サブディレクトリ実行でも最寄りのrepo_rootでproject_keyを選ぶ() {
  _fixture
  _add_unrelated_project
  mkdir -p "$FIXTURE_REPO/nested/child"
  _execute_report_from "$FIXTURE_REPO/nested/child" --days 0 >/dev/null 2>&1
  report="$(_report)"
  assert_contains "$report" "81,323" "対象repoのみの合計"
  assert_not_contains "$report" "81,547" "fallbackで混ざる他project合計"
  assert_not_contains "$report" "other-project-model" "無関係projectのmodel"
  assert_not_contains "$report" "フォールバック" "subdir実行時の誤fallback"
}

test_壊れたJSONLとcontent型違いでもトレースバックを出さない() {
  _run_report --days 1 >/dev/null 2>"$TEST_TMP/engine.err"
  status=$?
  assert_eq "0" "$status" "壊れた入力でも終了コード"
  err="$(cat "$TEST_TMP/engine.err")"
  assert_not_contains "$err" "Traceback" "トレースバック"
}

test_非scalarのmessage_idと不正数値を安全に無視する() {
  _fixture
  project_dir="$(find "$FIXTURE_HOME/.claude/projects" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  python3 - "$project_dir/session.jsonl" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
rows = [
    {"type": "assistant", "timestamp": stamp, "requestId": {"bad": "dict"},
     "message": {"id": {"bad": "dict"}, "model": "safe-dict-id-model",
                 "usage": {"input_tokens": 1, "cache_creation_input_tokens": 10,
                           "cache_read_input_tokens": 100, "output_tokens": 1}, "content": []}},
    {"type": "assistant", "timestamp": stamp, "requestId": ["bad", "list"],
     "message": {"id": ["bad", "list"], "model": "safe-list-id-model",
                 "usage": {"input_tokens": 2, "cache_creation_input_tokens": 20,
                           "cache_read_input_tokens": 200, "output_tokens": 2}, "content": []}},
    {"type": "assistant", "timestamp": stamp,
     "message": {"id": "malformed-numbers", "model": "malformed-number-model",
                 "usage": {"input_tokens": -1, "cache_creation_input_tokens": True,
                           "cache_read_input_tokens": 3.5, "output_tokens": "9"}, "content": []}},
]
for bad in (-1, True, 1.5, "10"):
    rows.append({"type": "user", "timestamp": stamp,
                 "toolUseResult": {"agentType": "invalid-total-agent",
                                   "resolvedModel": "invalid-total-model",
                                   "totalTokens": bad,
                                   "usage": {"input_tokens": 999, "output_tokens": 999}}})
with open(path, "a", encoding="utf-8") as handle:
    for row in rows:
        handle.write(json.dumps(row) + "\n")
PYEOF
  _execute_report --days 0 >/dev/null 2>"$TEST_TMP/malformed.err"
  status=$?
  report="$(_report)"
  err="$(cat "$TEST_TMP/malformed.err")"
  assert_eq "0" "$status" "非scalar IDの終了コード"
  assert_contains "$report" "main 合計: **81,659**" "有効なtokenだけの合計"
  assert_contains "$report" "safe-dict-id-model" "dict ID行の有効usage"
  assert_contains "$report" "safe-list-id-model" "list ID行の有効usage"
  assert_not_contains "$report" "invalid-total-agent" "不正totalTokens"
  assert_not_contains "$err" "Traceback" "非scalar IDのトレースバック"
}

test_表示メタデータとMarkdown表を安全化する() {
  _fixture
  project_dir="$(find "$FIXTURE_HOME/.claude/projects" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  python3 - "$project_dir/session.jsonl" "$FIXTURE_REPO" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

path, repo = sys.argv[1:]
stamp = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
zero = {"input_tokens": 0, "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0, "output_tokens": 0}
row = {"type": "assistant", "timestamp": stamp,
       "message": {"id": "adversarial-metadata", "model": "model|PIPE_MODEL_SENTINEL",
                   "usage": zero, "content": [
           {"type": "tool_use", "name": "Agent",
            "input": {"subagent_type": "../../PATH_AGENT_SENTINEL"}},
           {"type": "tool_use", "name": "Agent", "input": {"subagent_type": ".."}},
           {"type": "tool_use", "name": "Agent",
            "input": {"subagent_type": "token=SECRET_AGENT_SENTINEL"}},
           {"type": "tool_use", "name": "Agent",
            "input": {"subagent_type": "AKIAIOSFODNN7EXAMPLE"}},
           {"type": "tool_use", "name": "mcp__server|PIPE_MCP_SENTINEL__call", "input": {}},
           {"type": "tool_use", "name": "mcp__<MCP_HTML_SENTINEL>__call", "input": {}},
           {"type": "tool_use", "name": "mcp__AIzaSyA_example_key_1234567890__call", "input": {}},
           {"type": "tool_use", "name": "Read",
            "input": {"file_path": repo + "/safe|PIPE_PATH_SENTINEL.md"}},
           {"type": "tool_use", "name": "Read",
            "input": {"file_path": repo + "/safe[LINK_CELL_SENTINEL](target).md"}},
           {"type": "tool_use", "name": "Read",
            "input": {"file_path": repo + "/token=SECRET_PATH_SENTINEL.md"}},
           {"type": "tool_use", "name": "Read",
            "input": {"file_path": repo + "/glpat-exampletoken1234567890.md"}},
       ]}}
results = [
    {"type": "user", "timestamp": stamp,
     "toolUseResult": {"agentType": "bad\nCONTROL_AGENT_SENTINEL",
                       "resolvedModel": "/abs/PATH_MODEL_SENTINEL", "totalTokens": 1}},
    {"type": "user", "timestamp": stamp,
     "toolUseResult": {"agentType": "safe-reviewer",
                       "resolvedModel": "sk-live-CREDENTIAL_MODEL_SENTINEL", "totalTokens": 1}},
    {"type": "user", "timestamp": stamp,
     "toolUseResult": {"agentType": "AKIAIOSFODNN7EXAMPLE",
                       "resolvedModel": "safe-model", "totalTokens": 1}},
    {"type": "user", "timestamp": stamp,
     "toolUseResult": {"agentType": "safe-credential-agent",
                       "resolvedModel": "AIzaSyA_example_key_1234567890", "totalTokens": 1}},
    {"type": "user", "timestamp": stamp,
     "toolUseResult": {"agentType": "glpat-exampletoken1234567890",
                       "resolvedModel": "safe-model", "totalTokens": 1}},
]
with open(path, "a", encoding="utf-8") as handle:
    for item in [row] + results:
        handle.write(json.dumps(item) + "\n")
PYEOF
  _execute_report --days 0 --paths >/dev/null 2>"$TEST_TMP/safe.err"
  report="$(_report)"
  assert_contains "$report" 'safe\|PIPE_PATH_SENTINEL.md' "pipeを含むrepo内相対パス"
  assert_contains "$report" 'safe\[LINK_CELL_SENTINEL\]\(target\).md' \
    "Markdown link形を含むrepo内相対パス"
  assert_contains "$report" '&lt;MCP_HTML_SENTINEL&gt;' "HTML形を含むMCP名"
  assert_not_contains "$report" '[LINK_CELL_SENTINEL](target)' "Markdown link注入"
  assert_not_contains "$report" '<MCP_HTML_SENTINEL>' "HTML tag注入"
  assert_not_contains "$report" '| .. |' "path-like metadata"
  for leaked in PIPE_MODEL_SENTINEL PATH_AGENT_SENTINEL SECRET_AGENT_SENTINEL \
    PIPE_MCP_SENTINEL SECRET_PATH_SENTINEL CONTROL_AGENT_SENTINEL PATH_MODEL_SENTINEL \
    CREDENTIAL_MODEL_SENTINEL AKIAIOSFODNN7EXAMPLE \
    AIzaSyA_example_key_1234567890 glpat-exampletoken1234567890; do
    assert_not_contains "$report" "$leaked" "危険な表示値 $leaked"
  done
  assert_contains "$report" "plot-adversarial-reviewer" "安全なsubagent名"
  assert_contains "$report" "example-server" "安全なMCP名"
}

test_project_directory_keyをレポートへ出さない() {
  _fixture
  raw_key="$(basename "$(find "$FIXTURE_HOME/.claude/projects" -mindepth 1 -maxdepth 1 -type d -print -quit)")"
  [ -n "$raw_key" ] || _fail "project directory key fixture が空である"
  _execute_report --days 0 >/dev/null 2>&1
  report="$(_report)"
  assert_not_contains "$report" "$raw_key" "raw project directory key"
  assert_contains "$report" "走査したプロジェクト: 1 件" "project件数"
}

test_gitfileを持つlinked_worktreeのnested_cwdをrootにする() {
  _fixture
  rm -rf "$FIXTURE_REPO/.git"
  printf 'gitdir: %s\n' "$TEST_TMP/opaque-gitdir" >"$FIXTURE_REPO/.git"
  mkdir -p "$FIXTURE_REPO/nested/worktree-child"
  _execute_report_from "$FIXTURE_REPO/nested/worktree-child" --days 0 \
    >/dev/null 2>"$TEST_TMP/worktree.err"
  report="$(_report)"
  assert_contains "$report" "81,323" "linked worktreeの対象repo合計"
  assert_not_contains "$report" "フォールバック" "gitfileの誤fallback"
}

test_default_fallbackをstderrとreportへpath安全に警告する() {
  _fixture
  original="$(find "$FIXTURE_HOME/.claude/projects" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  raw_key="RAW-SECRET-PROJECT-KEY"
  mv "$original" "$FIXTURE_HOME/.claude/projects/$raw_key"
  _execute_report_from "$FIXTURE_REPO" --days 0 >/dev/null 2>"$TEST_TMP/fallback.err"
  status=$?
  report="$(_report)"
  err="$(cat "$TEST_TMP/fallback.err")"
  warning="警告: 現在のリポジトリに対応する記録を特定できないため、利用可能な全プロジェクトを集計した。"
  assert_eq "0" "$status" "fallback終了コード"
  assert_contains "$report" "$warning" "reportのfallback警告"
  assert_contains "$err" "$warning" "stderrのfallback警告"
  assert_not_contains "$report$err" "$raw_key" "fallback警告のraw key"
}

test_入力と設定とリポジトリを変更しない() {
  _fixture
  before="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_CONFIG" -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  CLAUDE_CONFIG_DIR_OVERRIDE="$FIXTURE_CONFIG" _execute_report --all-projects --days 0 \
    >/dev/null 2>"$TEST_TMP/engine.err"
  after="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_CONFIG" -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  assert_eq "$before" "$after" "入力・設定・リポジトリの指紋"
  pyc="$(find "$FIXTURE_HOME" "$FIXTURE_REPO" "$FIXTURE_CONFIG" \( -name '*.pyc' -o -name '__pycache__' \) 2>/dev/null)"
  assert_empty "$pyc" "pyc残留"
}
