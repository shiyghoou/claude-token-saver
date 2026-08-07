#!/usr/bin/env bash
# install.sh の検証。導入先の既存設定を壊さないこと、二度実行しても重複しないことが要点。

INSTALL="$REPO_ROOT/install.sh"

_setup_target() {
  TARGET="$TEST_TMP/target"
  mkdir -p "$TARGET"
  ( cd "$TARGET" && git init -q . )
  SETTINGS="$TARGET/.claude/settings.local.json"
}

_run_install() {
  bash "$INSTALL" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  INSTALL_STATUS=$?
  INSTALL_OUT="$(cat "$TEST_TMP/.out")"
  INSTALL_ERR="$(cat "$TEST_TMP/.err")"
}

_run_install_args() {
  bash "$INSTALL" "$@" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  INSTALL_STATUS=$?
  INSTALL_OUT="$(cat "$TEST_TMP/.out")"
  INSTALL_ERR="$(cat "$TEST_TMP/.err")"
}

_write_calibration_fixture() {
  CALIBRATION_CONFIG="$TARGET/.claude/token-saver.json"
  CALIBRATION_LATEST="$TARGET/.token-saver/calibration/latest.json"
  CALIBRATION_CLAUDE_CONFIG_DIR="$TEST_TMP/token-calibrate-empty-home/.claude"
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver/calibration" \
    "$CALIBRATION_CLAUDE_CONFIG_DIR/projects"
  python3 - "$CALIBRATION_CONFIG" "$CALIBRATION_LATEST" "$REPO_ROOT" \
    "$CALIBRATION_CLAUDE_CONFIG_DIR" <<'PYEOF'
import json
import os
import runpy
import sys

config_path, snapshot_path, repo_root, claude_dir = sys.argv[1:]
config = {
    "suggest_session_cut": {
        "initial_cache_read": 30000000,
        "increment_cache_read": 30000000,
    },
}
snapshot = {
    "eligible": True,
    "period": "全期間",
    "min_sessions": 5,
    "min_assistant_turns": 100,
    "percentile": 75,
    "exclude_below_assistant_turns": 3,
    "session_count": 5,
    "sample_session_count": 5,
    "total_session_count": 5,
    "excluded_session_count": 0,
    "assistant_turns": 100,
    "baseline_cache_read": 18000000,
    "distribution": {"p50": 18000000, "p75": 18000000, "p90": 18000000, "p95": 18000000},
    "concentration": {
        "top_n": 3,
        "share": 0.6,
        "cache_read_sum_top": 54000000,
        "cache_read_sum_all": 90000000,
    },
    "current_initial": 30000000,
    "current_increment": 30000000,
    "recommended_levels": [18000000, 36000000, 54000000],
    "fingerprint": "b" * 64,
    "source": "メインセッションの重複排除後 cache_read p75（assistant_turns>=3 を母集団）",
    "generated_at": "2026-08-04T00:00:00.000000Z",
    "scan_days": 0,
    "all_projects": False,
}
os.environ["CLAUDE_CONFIG_DIR"] = claude_dir
fixture_root = os.path.dirname(os.path.dirname(config_path))
previous_cwd = os.getcwd()
os.chdir(fixture_root)
engine = runpy.run_path(os.path.join(repo_root, "scripts", "measure-token-usage.py"))
args = type("CalibrationArgs", (object,), {})()
args.days = 0
args.all_projects = False
project_dirs, fell_back = engine["select_project_dirs"](args)
main_paths, sub_paths = engine["transcript_paths"](project_dirs)
snapshot["fingerprint"] = engine["calibration_fingerprint"](
    args,
    None,
    {
        "min_sessions": 5,
        "min_assistant_turns": 100,
        "percentile": 75,
        "exclude_below_assistant_turns": 3,
    },
    main_paths,
    sub_paths,
    project_dirs,
    fell_back,
)
os.chdir(previous_cwd)
for path, data in ((config_path, config), (snapshot_path, snapshot)):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
PYEOF
}

# settings.local.json から指定フックのコマンド一覧を HOOK_COMMANDS へ読み込む。
# 「登録が消えた」と「ファイルが読めなかった」を取り違えないため、
# 不在は明示的な文言を返し、解析できないときはテストを失敗させる。
# コマンド置換の中で呼ぶと _fail のサブシェル脱出が握り潰されるので、
# 変数へ入れる形にしている。
_load_hook_commands() {
  local event="$1"
  if [ ! -f "$SETTINGS" ]; then
    HOOK_COMMANDS='(settings.local.json は存在しない)'
    return 0
  fi
  HOOK_COMMANDS="$(python3 -c '
import json, sys
event = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
for group in data.get("hooks", {}).get(event, []):
    for h in group.get("hooks", []):
        print(h.get("command", ""))
' "$event" "$SETTINGS" 2>"$TEST_TMP/.hookerr")" ||
    _fail "settings.local.json を解析できない: $(cat "$TEST_TMP/.hookerr")"
}

_hook_commands() {
  _load_hook_commands "$1" || exit 1
  printf '%s\n' "$HOOK_COMMANDS"
}

# settings.local.json から指定フックの matcher 一覧を HOOK_MATCHERS へ読み込む。
# matcher が無いグループは空行で表し、利用者の既存グループと自前グループを
# 位置で取り違えないよう、設定の並びをそのまま返す。
_load_hook_matchers() {
  local event="$1"
  if [ ! -f "$SETTINGS" ]; then
    HOOK_MATCHERS='(settings.local.json は存在しない)'
    return 0
  fi
  HOOK_MATCHERS="$(python3 -c '
import json, sys
event = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
for group in data.get("hooks", {}).get(event, []):
    print(group.get("matcher", ""))
' "$event" "$SETTINGS" 2>"$TEST_TMP/.matchererr")" ||
    _fail "settings.local.json のmatcherを解析できない: $(cat "$TEST_TMP/.matchererr")"
}

_hook_matchers() {
  _load_hook_matchers "$1" || exit 1
  printf '%s\n' "$HOOK_MATCHERS"
}

# パーミッションを 8 進で返す。GNU と BSD で書式が違う。
_perm() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

test_settings_が無ければ作って_SessionStart_に登録する() {
  _setup_target
  _run_install
  local matchers
  matchers="$(_hook_matchers SessionStart)"
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$SETTINGS"
  assert_contains "$(_hook_commands SessionStart)" "handoff-check.sh" "SessionStart のコマンド"
  assert_eq "startup|clear" "$matchers" "SessionStart のmatcher"
}

test_生成した_settings_は妥当な_JSON_である() {
  _setup_target
  _run_install
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" ||
    _fail "settings.local.json が妥当な JSON でない"
}

test_二度実行してもフックが重複しない() {
  _setup_target
  _run_install
  _run_install
  local matchers
  matchers="$(_hook_matchers SessionStart)"
  assert_eq "0" "$INSTALL_STATUS" "2回目の終了コード"
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "handoff-check.sh の登録数"
  assert_eq "startup|clear" "$matchers" "SessionStart のmatcher"
}

test_既存の他フックを壊さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo 既存のフック" } ] }
    ]
  }
}
EOF
  _run_install
  local cmds
  cmds="$(_hook_commands SessionStart)"
  assert_contains "$cmds" "既存のフック" "SessionStart のコマンド"
  assert_contains "$cmds" "handoff-check.sh" "SessionStart のコマンド"
}

test_既存の他設定キーを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  assert_contains "$(cat "$SETTINGS")" "Bash(ls:*)" "settings.local.json"
}

test_壊れた_settings_は上書きせず失敗する() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"hooks": \n' >"$SETTINGS"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$(cat "$SETTINGS")" '{"hooks":' "settings.local.json（原状のまま）"
}

test_gitignore_に状態ディレクトリを追記する() {
  _setup_target
  _run_install
  local gi
  gi="$(cat "$TARGET/.gitignore")"
  assert_contains "$gi" ".token-saver/" ".gitignore"
}

test_gitignore_への追記は二度実行しても重複しない() {
  _setup_target
  _run_install
  _run_install
  assert_count 1 "$(cat "$TARGET/.gitignore")" ".token-saver/" ".gitignore の追記"
}

test_既存の_gitignore_の内容を消さない() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" "node_modules/" ".gitignore"
}

test_スキルを導入先へリンクする() {
  _setup_target
  _run_install
  assert_file_exists "$TARGET/.claude/skills/session-handoff/SKILL.md"
}

test_delegation_policyをリンクし台帳とgitignoreへ記録する() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" \
    '"name": "delegation-policy"' "台帳"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/skills/delegation-policy" ".gitignore"
}

test_delegation_policyをコピー配置できる() {
  _setup_target
  local status=0
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >"$TEST_TMP/.out" 2>&1 || status=$?
  assert_eq "0" "$status" "終了コード"
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/.claude-token-saver"
}

test_Codex対応スキルを_agentsへリンクする() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  [ -L "$TARGET/.agents/skills/delegation-policy" ] ||
    _fail "Codex対応スキルがシンボリックリンクではない"
  assert_eq "$REPO_ROOT/skills/delegation-policy" \
    "$(readlink "$TARGET/.agents/skills/delegation-policy")" "Codexリンク先"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/agents/openai.yaml"
  assert_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_Claudeのlegacy風managed_linkを現srcへ張り替える() {
  _setup_target
  old_repo="$TEST_TMP/old-repo"
  old_link="$old_repo/skills/delegation-policy"
  mkdir -p "$old_link" "$old_repo/lib" "$TARGET/.claude/skills"
  printf '#!/usr/bin/env bash\n' >"$old_repo/install.sh"
  : >"$old_repo/uninstall.sh"
  : >"$old_repo/lib/ledger.py"
  ln -s "$old_link" "$TARGET/.claude/skills/delegation-policy"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_eq "$REPO_ROOT/skills/delegation-policy" \
    "$(readlink "$TARGET/.claude/skills/delegation-policy")" "Claude legacy link"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/skills/delegation-policy" "Claude .gitignore"
}

test_Codexの台帳一致linkを現srcへ張り替えsharedで除外する() {
  _setup_target
  old_repo="$TEST_TMP/old-repo"
  old_link="$old_repo/skills/delegation-policy"
  mkdir -p "$old_link" "$TARGET/.agents/skills" "$TARGET/.token-saver"
  ln -s "$old_link" "$TARGET/.agents/skills/delegation-policy"
  python3 - "$TARGET/.token-saver/installed.json" "$old_link" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as handle:
    json.dump({"skills": [{"name": "delegation-policy", "src": sys.argv[2], "mode": "link"}]}, handle)
    handle.write("\n")
PY
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "personal終了コード"
  assert_eq "$REPO_ROOT/skills/delegation-policy" \
    "$(readlink "$TARGET/.agents/skills/delegation-policy")" "Codex ledger link"
  assert_file_missing "$TARGET/.gitignore" "personal後の.gitignore"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "shared終了コード"
  assert_eq "$REPO_ROOT/skills/delegation-policy" \
    "$(readlink "$TARGET/.agents/skills/delegation-policy")" "shared後のCodex link"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".agents/skills/delegation-policy" "Codex shared .gitignore"
}

test_Codex対応スキルをmarker付きcopyで配置する() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/.claude-token-saver"
}

test_metadata無しスキルを_agentsへ配置しない() {
  _setup_target
  _run_install
  assert_file_missing "$TARGET/.agents/skills/session-handoff"
  assert_file_missing "$TARGET/.agents/skills/token-report"
}

test_利用者所有のCodex同名directoryを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills/delegation-policy"
  printf '利用者のCodex方針\n' >"$TARGET/.agents/skills/delegation-policy/SKILL.md"
  _run_install
  assert_contains "$(cat "$TARGET/.agents/skills/delegation-policy/SKILL.md")" "利用者のCodex方針" "同名保護"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_利用者所有のCodex同名fileを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills"
  printf '利用者のfile\n' >"$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_contains "$(cat "$TARGET/.agents/skills/delegation-policy")" "利用者のfile" "同名file"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_利用者所有のCodex同名linkを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TEST_TMP/user-skill" "$TARGET/.agents/skills"
  printf '利用者のlink\n' >"$TEST_TMP/user-skill/SKILL.md"
  ln -s "$TEST_TMP/user-skill" "$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_eq "$TEST_TMP/user-skill" "$(readlink "$TARGET/.agents/skills/delegation-policy")" "foreign link"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_Codexのlegacy風foreign_linkを所有扱いしない() {
  _setup_target
  foreign_repo="$TEST_TMP/foreign-repo"
  foreign_link="$foreign_repo/skills/delegation-policy"
  mkdir -p "$foreign_link" "$TARGET/.agents/skills"
  printf '#!/usr/bin/env bash\n' >"$foreign_repo/install.sh"
  ln -s "$foreign_link" "$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_eq "$foreign_link" \
    "$(readlink "$TARGET/.agents/skills/delegation-policy")" "Codex foreign link"
  assert_not_contains "$(cat "$TARGET/.gitignore")" \
    ".agents/skills/delegation-policy" "foreign Codex .gitignore"
}

test_agents_parent_symlinkは変更前に拒否する() {
  _setup_target
  mkdir -p "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.claude/settings.local.json"
  assert_file_missing "$TEST_TMP/outside/skills"
}

test_agents_skills_parent_symlinkは変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.agents" "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents/skills"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.claude/settings.local.json"
  assert_file_missing "$TEST_TMP/outside/delegation-policy"
}

test_personal後のsharedは実所有Codexスキルだけを除外する() {
  _setup_target
  bash "$INSTALL" --personal "$TARGET" >/dev/null 2>&1
  assert_file_missing "$TARGET/.gitignore"
  bash "$INSTALL" --shared "$TARGET" >/dev/null 2>&1
  assert_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/session-handoff" ".gitignore"
}

test_Codex同名衝突でもClaude側は従来どおり配置する() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills/delegation-policy"
  printf '利用者のCodex方針\n' >"$TARGET/.agents/skills/delegation-policy/SKILL.md"
  _run_install
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" '"name": "delegation-policy"' "台帳"
}

test_利用者所有のClaude側delegation_policyは保護しCodex側だけ記録する() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/delegation-policy"
  printf '利用者の方針\n' >"$TARGET/.claude/skills/delegation-policy/SKILL.md"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$(cat "$TARGET/.claude/skills/delegation-policy/SKILL.md")" \
    "利用者の方針" "同名保護"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md" "Codex側の配置"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" \
    '"name": "delegation-policy"' "Codex側の台帳"
  assert_not_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/skills/delegation-policy" ".gitignore"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".agents/skills/delegation-policy" ".gitignore"
}

test_スキルのリンクは二度実行しても失敗しない() {
  _setup_target
  _run_install
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "2回目の終了コード"
  assert_file_exists "$TARGET/.claude/skills/session-handoff/SKILL.md"
}

test_導入先の他のスキルを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/my-own-skill"
  printf 'mine\n' >"$TARGET/.claude/skills/my-own-skill/SKILL.md"
  _run_install
  assert_file_exists "$TARGET/.claude/skills/my-own-skill/SKILL.md"
}

test_シンボリックリンクが使えない環境ではコピーする() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >"$TEST_TMP/.out" 2>&1
  assert_eq "0" "$?" "終了コード"
  local link="$TARGET/.claude/skills/session-handoff"
  if [ -L "$link" ]; then
    _fail "コピーへ退避すべき場面でシンボリックリンクが作られている"
  fi
  assert_file_exists "$link/SKILL.md"
  assert_contains "$(cat "$TEST_TMP/.out")" "コピー" "出力"
}

test_引き継ぎディレクトリを作る() {
  _setup_target
  _run_install
  assert_file_exists "$TARGET/.token-saver/handoff/pending"
  assert_file_exists "$TARGET/.token-saver/handoff/consumed"
}

test_新パスに引き継ぎのディレクトリを作る() {
  _setup_target
  _run_install
  assert_file_exists "$TARGET/.token-saver/handoff/pending" "pending"
  assert_file_exists "$TARGET/.token-saver/handoff/consumed" "consumed"
}

test_台帳を新パスに置く() {
  _setup_target
  _run_install
  assert_file_exists "$TARGET/.token-saver/installed.json" "台帳"
}

test_claude_配下に引き継ぎのディレクトリを作らない() {
  _setup_target
  _run_install
  assert_file_missing "$TARGET/.claude/.handoff" "旧の引き継ぎ置き場"
  assert_file_missing "$TARGET/.claude/.token-saver" "旧の状態置き場"
}

test_旧パスの引き継ぎを新パスへ移す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.claude/.handoff/consumed"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf 'B\n' >"$TARGET/.claude/.handoff/consumed/b.md"
  _run_install
  assert_eq "A" "$(cat "$TARGET/.token-saver/handoff/pending/a.md")" "pending の中身"
  assert_eq "B" "$(cat "$TARGET/.token-saver/handoff/consumed/b.md")" "consumed の中身"
  assert_file_missing "$TARGET/.claude/.handoff/pending/a.md" "旧 pending"
  assert_file_missing "$TARGET/.claude/.handoff/consumed/b.md" "旧 consumed"
}

test_旧パスのdotfile引き継ぎを新パスへ移す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'dotfileの本文\n' >"$TARGET/.claude/.handoff/pending/.draft.md.swp"
  _run_install
  assert_eq "dotfileの本文" \
    "$(cat "$TARGET/.token-saver/handoff/pending/.draft.md.swp")" \
    "dotfileの移行内容"
  assert_file_missing "$TARGET/.claude/.handoff/pending/.draft.md.swp" \
    "旧側のdotfile"
}

test_旧パスの台帳を新パスへ移す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.token-saver"
  printf '{"skills":{}}\n' >"$TARGET/.claude/.token-saver/installed.json"
  _run_install
  assert_file_exists "$TARGET/.token-saver/installed.json" "新台帳"
  assert_file_missing "$TARGET/.claude/.token-saver/installed.json" "旧台帳"
}

test_移行後は空になった旧ディレクトリを消す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.claude/.token-saver"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _run_install
  assert_file_missing "$TARGET/.claude/.handoff" "旧引き継ぎ置き場"
  assert_file_missing "$TARGET/.claude/.token-saver" "旧状態置き場"
}

test_新側に同名があれば上書きせず警告する() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.token-saver/handoff/pending"
  printf 'OLD\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf 'NEW\n' >"$TARGET/.token-saver/handoff/pending/a.md"
  _run_install
  assert_eq "NEW" "$(cat "$TARGET/.token-saver/handoff/pending/a.md")" "新側は無傷"
  assert_eq "OLD" "$(cat "$TARGET/.claude/.handoff/pending/a.md")" "旧側は残る"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "警告" "衝突を警告する"
}

# 「移行が起きたら適用一覧に載せる」という名前だったが、実際に検証していたのは
# info の出力だけで、applied 配列そのものは検証していなかった（レビュー指摘）。
# info による告知自体は「黙って動かさない」という別の性質として引き続き値打ちが
# あるため、名前を実態に合わせて改名し、削除の非退行として残す。applied 配列の
# 実際の使い道（die したときに「ここまで適用した」へ載ること）は、直後の
# test_移行の途中で失敗しても移した分は適用一覧に伝わる で検証する。
test_移行が起きたことを利用者に伝える() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _run_install
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "移行" "移行したことを伝える"
}

# 移行の対象は pending/ consumed/ installed.json の3つに限る。それ以外の
# 迷子ファイル（引き継ぎの器の直下に直接置かれた1ファイル）は移されず、
# rmdir が「空でない」ため失敗して器が残る。器が残ること自体はよいが、
# 黙っていると次の git status に新規の未追跡ファイルとして突然現れる
# （旧パスの gitignore ブロックは、この直後の .gitignore 再生成で新パスへ
# 差し替わるため、旧側はもう無視されない）。警告で気づけることを確かめる。
test_旧パスの迷子ファイルは移行されず警告する() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff"
  printf '迷子\n' >"$TARGET/.claude/.handoff/notes.md"
  _run_install
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "未移行" "取り残しを警告する"
  assert_file_exists "$TARGET/.claude/.handoff/notes.md" "迷子ファイルは残る（消さない）"
}

# applied は「途中で die したときに何が残っているか」を利用者に伝える唯一の手段
# （install.sh 冒頭の die() のコメント参照）。移行の完了を待ってから1件だけ積むと、
# 一部のファイルを移した直後に別のファイルの移行で die したとき、既に移した分が
# 「ここまで適用した」一覧から漏れる。pending は書き込み可能なまま移行させて
# 先に完了させ、consumed の移行先だけ書き込み不可にして意図的に die させる。
#
# root（CI コンテナ等）で走らせるとこのテストは赤になる。root は書き込み不可の
# ディレクトリでも mv を成功させてしまうため、chmod 555 が意図した「移行の途中
# で失敗する」状況をそもそも作れず、die が起きずに INSTALL_STATUS が 0 のまま
# 通ってしまう。CI コンテナでだけこれが再現したときに原因探しで時間を溶かさない
# よう、ここに明記しておく。テストを root で走らせないこと。
test_移行の途中で失敗しても移した分は適用一覧に伝わる() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.claude/.handoff/consumed" \
           "$TARGET/.token-saver/handoff/consumed"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf 'B\n' >"$TARGET/.claude/.handoff/consumed/b.md"
  chmod 555 "$TARGET/.token-saver/handoff/consumed"
  _run_install
  chmod 755 "$TARGET/.token-saver/handoff/consumed" 2>/dev/null || true
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$INSTALL_ERR" "a.md" "先に移した pending が適用一覧に載る"
}

test_旧パスが無ければ移行を報告しない() {
  _setup_target
  _run_install
  assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "移行" "新規導入では移行に触れない"
}

test_旧パスのシンボリックリンクはリンクごと移す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'OUTSIDE\n' >"$TEST_TMP/outside.md"
  ln -s "$TEST_TMP/outside.md" "$TARGET/.claude/.handoff/pending/link.md"
  _run_install
  # リンクが実体化していないこと。実体化すると、リンク先の検証を
  # 読み取り時に行う設計（handoff-check.sh）が空回りする。
  if [ ! -L "$TARGET/.token-saver/handoff/pending/link.md" ]; then
    _fail "移行でシンボリックリンクが実体化した"
  fi
  assert_file_missing "$TARGET/.claude/.handoff/pending/link.md" "旧側のリンク"
}

# 新側に壊れたシンボリックリンクがあると [ -e ] は偽になる。[ -L ] を落とすと
# 「無いも同然」と誤認して旧側の実ファイルで上書きしてしまう。衝突判定は
# 実体の有無ではなく、そこに何か（リンクを含む）があるかで見なければならない。
test_新側の壊れたリンクは実ファイルで上書きされない() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.token-saver/handoff/pending"
  printf 'OLD\n' >"$TARGET/.claude/.handoff/pending/a.md"
  ln -s "$TEST_TMP/does-not-exist.md" "$TARGET/.token-saver/handoff/pending/a.md"
  _run_install
  assert_eq "OLD" "$(cat "$TARGET/.claude/.handoff/pending/a.md")" "旧側は残る"
  if [ ! -L "$TARGET/.token-saver/handoff/pending/a.md" ]; then
    _fail "新側の壊れたリンクが実ファイルで上書きされた"
  fi
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "警告" "衝突を警告する"
}

test_台帳が新旧にあれば新台帳を上書きせず警告する() {
  _setup_target
  mkdir -p "$TARGET/.claude/.token-saver" "$TARGET/.token-saver"
  # lib/ledger.py の skills は配列（get_list）である。辞書で書くと
  # get_list が [] とみなして丸ごと落ちてしまい、衝突の有無に関わらず
  # マーカーが消える誤検出になるため、実際のスキーマに合わせる。
  printf '{"skills":[{"name":"legacy-marker","src":"/x","mode":"link"}]}\n' \
    >"$TARGET/.claude/.token-saver/installed.json"
  printf '{"skills":[{"name":"new-marker","src":"/y","mode":"link"}]}\n' \
    >"$TARGET/.token-saver/installed.json"
  _run_install
  assert_file_exists "$TARGET/.claude/.token-saver/installed.json" "旧台帳は残る"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" "new-marker" "新台帳の既存内容が保たれる"
  assert_not_contains "$(cat "$TARGET/.token-saver/installed.json")" "legacy-marker" "旧台帳の内容を持ち込んでいない"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "警告" "衝突を警告する"
}

test_gitignore_はルート直下の1行で覆う() {
  _setup_target
  _run_install
  local gi
  gi="$(cat "$TARGET/.gitignore")"
  assert_contains "$gi" ".token-saver/" ".gitignore"
  assert_not_contains "$gi" ".claude/.handoff/" ".gitignore"
  assert_not_contains "$gi" ".claude/.token-saver/" ".gitignore"
}

test_gitignore_はスキルの行を残す() {
  _setup_target
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" \
    ".gitignore"
}

test_非_git_ディレクトリでも失敗しない() {
  _setup_target
  rm -rf "$TARGET/.git"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$SETTINGS"
}

test_Stopフックを登録する() {
  _setup_target
  _run_install
  # Task 2 以降は Stop フックの実体が常に存在し、install が登録まで担う。
  # 「実装済み」と文書に書きながら導入時に登録されない状態を防ぐ。
  _load_hook_commands Stop
  assert_contains "$HOOK_COMMANDS" "suggest-session-cut.sh" "Stop のコマンド"
}

test_Stopフック実体を欠くクローンなら登録せず警告する() {
  _setup_target
  local clone="$TEST_TMP/missing-stop-hook" rc=0 out
  _clone_repo "$clone"
  rm -f "$clone/scripts/suggest-session-cut.sh"

  bash "$clone/install.sh" "$TARGET" >"$TEST_TMP/.out" 2>&1 || rc=$?
  out="$(cat "$TEST_TMP/.out")"
  _load_hook_commands Stop

  assert_eq "0" "$rc" "終了コード"
  assert_not_contains "$HOOK_COMMANDS" "suggest-session-cut.sh" "Stop のコマンド"
  assert_contains "$out" "クローンが不完全なため Stop フックを登録しない" "欠損警告"
}

test_二度実行しても_Stopフックが重複しない() {
  _setup_target
  _run_install
  _run_install
  _load_hook_commands Stop
  assert_eq "0" "$INSTALL_STATUS" "2回目の終了コード"
  assert_count 1 "$HOOK_COMMANDS" "suggest-session-cut.sh" "Stop の登録数"
}

test_登録されるコマンドは絶対パスである() {
  _setup_target
  _run_install
  local cmd
  cmd="$(_hook_commands SessionStart | grep handoff-check.sh)"
  case "$cmd" in
    /*) ;;
    *) _fail "登録コマンドが絶対パスでない: $cmd" ;;
  esac
}

test_登録されたフックがそのまま実行できる() {
  _setup_target
  _run_install
  mkdir -p "$TARGET/.token-saver/handoff/pending"
  printf '実行できる引き継ぎ\n' >"$TARGET/.token-saver/handoff/pending/a.md"

  local cmd out
  cmd="$(_hook_commands SessionStart | grep handoff-check.sh)"
  out="$(printf '{"source":"startup","cwd":"%s"}' "$TARGET" | CLAUDE_PROJECT_DIR="$TARGET" bash -c "$cmd")"
  assert_contains "$out" "実行できる引き継ぎ" "フック出力"
}

test_導入先が自前で置いた同名スキルは上書きしない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/session-handoff"
  printf '導入先が自分で書いたもの\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "導入先が自分で書いたもの" "既存スキルの内容"
}

test_コピーで配置したスキルは再実行で更新される() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  printf '古い内容\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  assert_not_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "古い内容" "再配置後のスキル"
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "session-handoff" "再配置後のスキル"
}

test_gitignore_にスキルのリンクを追記する() {
  _setup_target
  _run_install
  # リンクは絶対パスを指す環境依存の産物である。版管理へ入れると
  # 他の開発者のクローンで壊れたリンクになる。
  ( cd "$TARGET" && git check-ignore -q .claude/skills/session-handoff ) ||
    _fail "スキルのリンクが gitignore されていない"
}

test_gitignore_の追記は既存の行と空行で区切る() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" "$(printf 'node_modules/\n\n# claude-token-saver')" ".gitignore"
}

test_末尾に改行が無い_gitignore_でも行が結合しない() {
  _setup_target
  printf 'node_modules/' >"$TARGET/.gitignore"
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" "$(printf 'node_modules/\n')" ".gitignore"
  assert_not_contains "$(cat "$TARGET/.gitignore")" "node_modules/#" ".gitignore"
}


# --- 以下、敵対的レビューの指摘に対する回帰テスト -----------------------------

GITIGNORE_START="# claude-token-saver (install.sh が追記。uninstall.sh で削除される)"
GITIGNORE_END="# claude-token-saver end"

# クローンを別の場所へ複製する。CTS_HOME 側のパスを変えた検証に使う。
_clone_repo() {
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$dest/"
  local d
  for d in scripts skills lib commands; do
    [ -d "$REPO_ROOT/$d" ] || continue
    # 作業ツリーに誤って残った __pycache__ を被験クローンへ持ち込まない。
    # install 本体が汚染するかの検証を壊さないための隔離である。
    mkdir -p "$dest/$d"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude '__pycache__' --exclude '*.pyc' "$REPO_ROOT/$d/" "$dest/$d/"
    else
      cp -R "$REPO_ROOT/$d/." "$dest/$d/"
      find "$dest/$d" -depth -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
      find "$dest/$d" -type f -name '*.pyc' -delete 2>/dev/null || true
    fi
  done
  return 0
}

# mtime を秒で返す。GNU (stat -c) と BSD/macOS (stat -f) の双方を見る。
# 取得できないまま空文字列を返すと assert_eq "" "" が成立し、実装を壊しても
# 緑のままになる。取得できなければテストを失敗させる。
_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" || m=""
  [ -n "$m" ] || m="$(stat -f %m "$1" 2>/dev/null)" || m=""
  [ -n "$m" ] || _fail "mtime を取得できない: $1"
  printf '%s\n' "$m"
}

# _mtime は $( ) の中で呼ぶため、_fail の exit が握り潰される。
# 先に一度だけ素で呼んで取得可能性を確かめる。
_require_mtime() { _mtime "$1" >/dev/null; }

test_クローンのパスに空白があってもフックが実行できる() {
  _setup_target
  local clone="$TEST_TMP/my clone"
  _clone_repo "$clone"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1

  mkdir -p "$TARGET/.token-saver/handoff/pending"
  printf '空白パスでも読める\n' >"$TARGET/.token-saver/handoff/pending/a.md"

  local cmd out
  cmd="$(_hook_commands SessionStart | grep handoff-check.sh)"
  out="$(printf '{"source":"startup","cwd":"%s"}' "$TARGET" |
    CLAUDE_PROJECT_DIR="$TARGET" bash -c "$cmd" 2>&1)"
  assert_contains "$out" "空白パスでも読める" "フック出力"
}

test_gitignore_のブロックは再実行で再生成される() {
  _setup_target
  _run_install
  # スキルが増えた／出力先が増えた場面を模す。ブロックの中身が欠けていても
  # 再実行で復元されないと、リンクが版管理対象として現れる。
  grep -v '^\.claude/skills/session-handoff$' "$TARGET/.gitignore" >"$TARGET/.gitignore.tmp"
  mv "$TARGET/.gitignore.tmp" "$TARGET/.gitignore"
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignore"
}

test_設置しなかったスキルは_gitignore_に書かない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/session-handoff"
  printf '導入先が自分で書いたもの\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  _run_install
  # 触らないと判断したスキルを無視すると、導入先の版管理から静かに消える。
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignore"
}

test_gitignore_に変化が無ければ書き込まない() {
  _setup_target
  _run_install
  touch -t 202001010000 "$TARGET/.gitignore"
  local before after
  _require_mtime "$TARGET/.gitignore"
  # runner-allow: 取得可能性を先に確認した上で、mtime値を比較するために捕捉する。
  before="$(_mtime "$TARGET/.gitignore")"
  _run_install
  # runner-allow: 取得可能性を先に確認した上で、mtime値を比較するために捕捉する。
  after="$(_mtime "$TARGET/.gitignore")"
  assert_eq "$before" "$after" ".gitignore の mtime"
}

test_gitignore_の_END_が無ければ何も削らず警告する() {
  _setup_target
  printf 'dist/\n%s\n.claude/.handoff/\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  _run_install
  assert_contains "$(cat "$TARGET/.gitignore")" "dist/" ".gitignore"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "警告" "出力"
}

test_綴りの違うパスから実行してもフックが重複しない() {
  _setup_target
  ln -s "$REPO_ROOT" "$TEST_TMP/link"
  bash "$TEST_TMP/link/install.sh" "$TARGET" >/dev/null 2>&1
  _run_install
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "handoff-check.sh の登録数"
}

test_移動した古いクローンを指す登録は掃除される() {
  _setup_target
  local clone="$TEST_TMP/old-clone"
  _clone_repo "$clone"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  rm -rf "$clone"
  _run_install
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "handoff-check.sh の登録数"
  assert_not_contains "$(_hook_commands SessionStart)" "old-clone" "SessionStart のコマンド"
}

test_matcher_付きのユーザー独自フックは残す() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "echo 独自フック" } ] }
    ]
  }
}
EOF
  _run_install
  _run_install
  local cmds matchers
  cmds="$(_hook_commands SessionStart)"
  matchers="$(_hook_matchers SessionStart)"
  assert_contains "$cmds" "独自フック" "SessionStart のコマンド"
  assert_contains "$(cat "$SETTINGS")" "matcher" "settings.local.json"
  assert_contains "$matchers" "startup|clear" "自前SessionStartのmatcher"
}

test_旧形式のSessionStart登録をmatcher付きへ移行する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver"
  python3 - "$SETTINGS" "$TARGET/.token-saver/installed.json" \
    "$REPO_ROOT/scripts/handoff-check.sh" <<'PY'
import json
import shlex
import sys

settings, ledger, command = sys.argv[1:]
quoted = shlex.quote(command)
with open(settings, "w") as f:
    json.dump({"hooks": {"SessionStart": [{"hooks": [
        {"type": "command", "command": quoted}
    ]}]}}, f)
with open(ledger, "w") as f:
    json.dump({"hooks": [quoted]}, f)
PY

  local out rc=0 matchers
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$TARGET/.token-saver/installed.json" \
    --matcher "SessionStart=startup|clear" \
    "SessionStart:$REPO_ROOT/scripts/handoff-check.sh" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "旧形式移行の終了コード: $out"
  matchers="$(_hook_matchers SessionStart)"
  assert_eq "startup|clear" "$matchers" "移行後のmatcher"
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "移行後の登録数"
}

test_不正なmatcher指定を設定変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver"
  printf '{"permissions":{}}\n' >"$SETTINGS"
  printf '{"skills":[]}\n' >"$TARGET/.token-saver/installed.json"
  cp "$SETTINGS" "$TEST_TMP/settings.before"
  cp "$TARGET/.token-saver/installed.json" "$TEST_TMP/ledger.before"

  local out rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$TARGET/.token-saver/installed.json" \
    --matcher SessionStart 2>&1)" || rc=$?
  assert_eq "64" "$rc" "不正matcherの終了コード"
  assert_contains "$out" "matcher の指定が妥当でない" "不正matcherのエラー"
  assert_eq "$(cat "$TEST_TMP/settings.before")" "$(cat "$SETTINGS")" "設定の未変更"
  assert_eq "$(cat "$TEST_TMP/ledger.before")" "$(cat "$TARGET/.token-saver/installed.json")" "台帳の未変更"
}

test_Codex用ledger_keyはClaude用hooks記録と分離する() {
  _setup_target
  local settings="$TARGET/codex-hooks.json" ledger="$TARGET/ledger.json"
  local command="$TARGET/codex hook.sh" out rc=0
  printf '{"hooks":["claude-command"]}\n' >"$ledger"
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
    --ledger "$ledger" --ledger-key codex_hooks \
    "SessionStart:$command" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "codex_hooks installの終了コード: $out"
  python3 - "$settings" "$ledger" "$command" <<'PY' || _fail "Codex用台帳の分離結果が妥当でない"
import json
import shlex
import sys

settings, ledger, command = sys.argv[1:]
with open(settings, encoding="utf-8") as handle:
    setting_data = json.load(handle)
with open(ledger, encoding="utf-8") as handle:
    ledger_data = json.load(handle)
expected = shlex.quote(command)
assert ledger_data["hooks"] == ["claude-command"]
assert ledger_data["codex_hooks"] == [expected]
assert setting_data["hooks"]["SessionStart"][0]["hooks"][0]["command"] == expected
PY
}

test_additional_context_limitは指定したeventのgroupだけへ入る() {
  _setup_target
  local settings="$TARGET/codex-hooks.json" ledger="$TARGET/ledger.json" rc=0
  printf '{}\n' >"$ledger"
  python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
    --ledger "$ledger" --ledger-key codex_hooks \
    --matcher 'SessionStart=startup|clear' \
    --additional-context-limit SessionStart=10000 \
    'SessionStart:echo session' 'Stop:echo stop' >/dev/null 2>"$TEST_TMP/.err" || rc=$?
  assert_eq "0" "$rc" "additionalContextLimitの終了コード: $(cat "$TEST_TMP/.err")"
  python3 - "$settings" <<'PY' || _fail "event別additionalContextLimitの構造が妥当でない"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
session = data["hooks"]["SessionStart"][0]
stop = data["hooks"]["Stop"][0]
assert session["matcher"] == "startup|clear"
session_entry = session["hooks"][0]
stop_entry = stop["hooks"][0]
assert session_entry["additionalContextLimit"] == 10000
assert "additionalContextLimit" not in session
assert "additionalContextLimit" not in stop_entry
PY
}

test_additional_context_limitは正整数以外と未指定eventを変更前に拒否する() {
  _setup_target
  local settings="$TARGET/codex-hooks.json" ledger="$TARGET/ledger.json" bad before_settings before_ledger rc out
  for bad in 0 -1 1.5 nope; do
    printf '{}\n' >"$settings"
    printf '{"codex_hooks":[]}\n' >"$ledger"
    before_settings="$(cat "$settings")"
    before_ledger="$(cat "$ledger")"
    rc=0
    out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
      --ledger "$ledger" --ledger-key codex_hooks \
      --additional-context-limit "SessionStart=$bad" \
      'SessionStart:echo session' 2>&1)" || rc=$?
    assert_eq "64" "$rc" "不正な上限[$bad]の終了コード"
    assert_contains "$out" "正の10進整数" "不正な上限[$bad]のエラー"
    assert_eq "$before_settings" "$(cat "$settings")" "不正な上限[$bad]の設定未変更"
    assert_eq "$before_ledger" "$(cat "$ledger")" "不正な上限[$bad]の台帳未変更"
  done

  printf '{}\n' >"$settings"
  printf '{"codex_hooks":[]}\n' >"$ledger"
  rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
    --ledger "$ledger" --ledger-key codex_hooks \
    --additional-context-limit Stop=10000 \
    'SessionStart:echo session' 2>&1)" || rc=$?
  assert_eq "64" "$rc" "未指定eventの終了コード"
  assert_contains "$out" "フック指定に無い" "未指定eventのエラー"
}

test_許可されないledger_keyは設定変更前に拒否する() {
  _setup_target
  local settings="$TARGET/codex-hooks.json" ledger="$TARGET/ledger.json" out rc=0
  printf '{}\n' >"$settings"
  printf '{"hooks":["keep"]}\n' >"$ledger"
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
    --ledger "$ledger" --ledger-key arbitrary \
    'SessionStart:echo session' 2>&1)" || rc=$?
  assert_eq "64" "$rc" "未知ledger_keyの終了コード"
  assert_contains "$out" "hooks または codex_hooks" "未知ledger_keyのエラー"
  assert_eq "$(printf '{}\n')" "$(cat "$settings")" "未知ledger_keyの設定未変更"
  assert_eq "$(printf '{\"hooks\":[\"keep\"]}\n')" "$(cat "$ledger")" "未知ledger_keyの台帳未変更"
}

test_明示したledger_keyはhooksでもcodex_hooksでも重複指定を拒否する() {
  _setup_target
  local settings="$TARGET/codex-hooks.json" ledger="$TARGET/ledger.json" key out rc before_settings before_ledger
  for key in hooks codex_hooks; do
    printf '{}\n' >"$settings"
    printf '{}\n' >"$ledger"
    before_settings="$(cat "$settings")"
    before_ledger="$(cat "$ledger")"
    rc=0
    out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$settings" \
      --ledger "$ledger" --ledger-key "$key" --ledger-key "$key" \
      'SessionStart:echo session' 2>&1)" || rc=$?
    assert_eq "64" "$rc" "重複ledger_key[$key]の終了コード"
    assert_contains "$out" "1回だけ" "重複ledger_key[$key]のエラー"
    assert_eq "$before_settings" "$(cat "$settings")" "重複ledger_key[$key]の設定未変更"
    assert_eq "$before_ledger" "$(cat "$ledger")" "重複ledger_key[$key]の台帳未変更"
  done
}

test_ledgerのhas_recordはCodexのhook記録を管理対象として数える() {
  local ledger="$TEST_TMP/ledger.json" rc
  printf '{"codex_hooks":[]}' >"$ledger"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record "$ledger" codex_hooks || rc=$?
  assert_eq "0" "$rc" "空のcodex_hooks記録"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record "$ledger" any || rc=$?
  assert_eq "0" "$rc" "codex_hooksのany記録"
  printf '{"codex_hooks_created":true}' >"$ledger"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record "$ledger" any || rc=$?
  assert_eq "0" "$rc" "codex_hooks_createdのany記録"
}

test_personal_installはCodexのSessionStart_hookとtrust案内を導入する() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "Codex personal installの終了コード"
  assert_file_exists "$TARGET/.codex/hooks.json" "Codex hooks.json"
  assert_contains "$INSTALL_OUT" "/hooks" "Codex hookのtrust案内"
  assert_contains "$INSTALL_OUT" "trust" "Codex hookのtrust案内"
  assert_not_contains "$INSTALL_OUT" "dangerously-bypass-hook-trust" "通常利用のtrust案内"
  python3 - "$TARGET/.codex/hooks.json" "$TARGET/.token-saver/installed.json" "$REPO_ROOT/scripts/handoff-check.sh" <<'PY' || _fail "Codex personal hookの導入結果が妥当でない"
import json
import shlex
import sys

hooks_path, ledger_path, command = sys.argv[1:]
with open(hooks_path, encoding="utf-8-sig") as handle:
    hooks = json.load(handle)
with open(ledger_path, encoding="utf-8") as handle:
    ledger = json.load(handle)
groups = hooks["hooks"]["SessionStart"]
assert len(groups) == 1
assert groups[0]["matcher"] == "startup|clear"
entries = groups[0]["hooks"]
assert len(entries) == 1
assert entries[0]["command"] == shlex.quote(command)
assert entries[0]["additionalContextLimit"] == 10000
assert ledger["codex_hooks"] == [shlex.quote(command)]
assert ledger["codex_hooks_created"] is True
assert ledger["codex_dir_created"] is True
PY
}

test_personal_installはCodex_hookを再実行しても重複させない() {
  _setup_target
  _run_install_args --personal
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "Codex再installの終了コード"
  python3 - "$TARGET/.codex/hooks.json" <<'PY' || _fail "Codex hookが再installで重複した"
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
entries = [
    entry
    for group in data["hooks"].get("SessionStart", [])
    for entry in group.get("hooks", [])
    if "handoff-check.sh" in entry.get("command", "")
]
assert len(entries) == 1
assert entries[0]["additionalContextLimit"] == 10000
PY
}

test_新規作成したCodex_hooks_jsonだけをmanaged_gitignoreへ追加する() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "新規Codex hooks.json installの終了コード"
  local gitignore status
  gitignore="$(cat "$TARGET/.gitignore")"
  assert_contains "$gitignore" ".codex/hooks.json" "新規Codex hooks.jsonのmanaged .gitignore"
  status="$(git -C "$TARGET" status --short -- .codex)"
  assert_empty "$status" "新規Codex hooks.jsonのgit status"
}

test_既存の利用者Codex_hooks_jsonはmanaged_gitignoreへ追加しない() {
  _setup_target
  mkdir -p "$TARGET/.codex"
  printf '%s\n' '{"custom":{"keep":true},"hooks":{}}' >"$TARGET/.codex/hooks.json"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "既存Codex hooks.json installの終了コード"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" \
    "既存Codex hooks.jsonのmanaged .gitignore"
  assert_contains "$(git -C "$TARGET" status --short -- .codex)" ".codex" \
    "既存Codex hooks.jsonのgit status"
}

test_追跡済みの利用者Codex_hooks_jsonはmanaged_gitignoreへ追加しない() {
  _setup_target
  mkdir -p "$TARGET/.codex"
  printf '%s\n' '{"custom":{"keep":true},"hooks":{}}' >"$TARGET/.codex/hooks.json"
  ( cd "$TARGET" && git add .codex/hooks.json )
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "追跡済みCodex hooks.json installの終了コード"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" \
    "追跡済みCodex hooks.jsonのmanaged .gitignore"
}

test_Codex_hooks_jsonの未知キー利用者hook他eventとBOMを保持する() {
  _setup_target
  mkdir -p "$TARGET/.codex"
  python3 - "$TARGET/.codex/hooks.json" <<'PY'
import json
import sys

data = {
    "custom": {"keep": True},
    "hooks": {
        "SessionStart": [
            {"description": "利用者説明", "hooks": [
                {"type": "command", "command": "echo 利用者SessionStart"}
            ]}
        ],
        "Stop": [
            {"hooks": [{"type": "command", "command": "echo 利用者Stop"}]}
        ],
    },
}
with open(sys.argv[1], "w", encoding="utf-8-sig") as handle:
    json.dump(data, handle, ensure_ascii=False)
PY
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "既存Codex hooks.json installの終了コード"
  python3 - "$TARGET/.codex/hooks.json" "$TARGET/.token-saver/installed.json" <<'PY' || _fail "既存Codex hooks.jsonの保持結果が妥当でない"
import json
import sys

path, ledger_path = sys.argv[1:]
with open(path, "rb") as handle:
    raw = handle.read()
assert raw.startswith(b"\xef\xbb\xbf")
with open(path, encoding="utf-8-sig") as handle:
    data = json.load(handle)
assert data["custom"] == {"keep": True}
session = data["hooks"]["SessionStart"]
stop = data["hooks"]["Stop"]
assert any(
    hook.get("command") == "echo 利用者SessionStart"
    for group in session for hook in group["hooks"]
)
assert any(
    hook.get("command") == "echo 利用者Stop"
    for group in stop for hook in group["hooks"]
)
managed = [
    hook
    for group in session
    for hook in group["hooks"]
    if "handoff-check.sh" in hook.get("command", "")
]
assert len(managed) == 1
assert managed[0]["additionalContextLimit"] == 10000
with open(ledger_path, encoding="utf-8") as handle:
    ledger = json.load(handle)
assert ledger["codex_hooks_created"] is False
assert ledger["codex_dir_created"] is False
PY
  assert_contains "$INSTALL_OUT" "/hooks" "既存Codex hookのtrust案内"
}

test_Codex_hooks_jsonの不正JSONと不正構造は変更前に拒否する() {
  _setup_target
  local invalid
  for invalid in '{"hooks": ' '{"hooks":[]}' '{"hooks":{"SessionStart":[{"hooks":{}}]}}'; do
    rm -rf "$TARGET/.claude" "$TARGET/.token-saver" "$TARGET/.codex"
    mkdir -p "$TARGET/.codex"
    printf '%s' "$invalid" >"$TARGET/.codex/hooks.json"
    _run_install_args --personal
    assert_ne "0" "$INSTALL_STATUS" "不正Codex hooks[$invalid]の終了コード"
    assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "完了" "不正Codex hooks[$invalid]の完了表示"
    assert_file_missing "$TARGET/.claude/settings.local.json" "不正Codex hooks[$invalid]のClaude設定変更"
    assert_file_missing "$TARGET/.token-saver/handoff" "不正Codex hooks[$invalid]の状態変更"
    assert_eq "$invalid" "$(cat "$TARGET/.codex/hooks.json")" "不正Codex hooks[$invalid]の原状"
  done
}

test_Codexの管理対象symlinkはpersonal変更前に拒否する() {
  _setup_target
  local kind outside="$TEST_TMP/codex-outside" before
  mkdir -p "$outside"
  for kind in parent hooks; do
    rm -rf "$TARGET/.claude" "$TARGET/.token-saver" "$TARGET/.codex"
    if [ "$kind" = "parent" ]; then
      ln -s "$outside" "$TARGET/.codex"
      before="parent-marker"
      printf '%s\n' "$before" >"$outside/marker"
    else
      mkdir -p "$TARGET/.codex"
      printf '%s\n' "hooks-marker" >"$outside/hooks.json"
      ln -s "$outside/hooks.json" "$TARGET/.codex/hooks.json"
      before="hooks-marker"
    fi
    _run_install_args --personal
    assert_ne "0" "$INSTALL_STATUS" "Codex $kind symlinkの終了コード"
    assert_file_missing "$TARGET/.token-saver/handoff" "Codex $kind symlinkの状態変更"
    if [ "$kind" = "parent" ]; then
      assert_file_exists "$TARGET/.codex" "Codex parent symlink"
      assert_eq "$before" "$(cat "$outside/marker")" "Codex parent symlinkの外部原状"
    else
      assert_file_exists "$TARGET/.codex/hooks.json" "Codex hooks symlink"
      assert_eq "$before" "$(cat "$outside/hooks.json")" "Codex hooks symlinkの外部原状"
    fi
  done
}

test_Codex台帳のsymlinkはpersonal変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.token-saver" "$TEST_TMP/ledger-outside"
  printf '{"hooks":[]}\n' >"$TEST_TMP/ledger-outside/installed.json"
  ln -s "$TEST_TMP/ledger-outside/installed.json" "$TARGET/.token-saver/installed.json"
  _run_install_args --personal
  assert_ne "0" "$INSTALL_STATUS" "Codex台帳symlinkの終了コード"
  assert_file_missing "$TARGET/.claude/settings.local.json" "Codex台帳symlinkのClaude設定変更"
  assert_file_missing "$TARGET/.token-saver/handoff" "Codex台帳symlinkの状態変更"
  assert_eq "$(printf '{\"hooks\":[]}\n')" "$(cat "$TEST_TMP/ledger-outside/installed.json")" "Codex台帳symlinkの外部原状"
}

test_shared_installはCodex個人hookを変更せずtrust案内もしない() {
  _setup_target
  mkdir -p "$TARGET/.codex"
  printf '{"custom":"keep"}\n' >"$TARGET/.codex/hooks.json"
  local before
  before="$(cat "$TARGET/.codex/hooks.json")"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "shared installの終了コード"
  assert_eq "$before" "$(cat "$TARGET/.codex/hooks.json")" "shared installのCodex hooks未変更"
  assert_not_contains "$INSTALL_OUT" "/hooks" "shared installのtrust案内"
}

test_sharedスコープはCodex作成所有権を台帳から読んでmanaged除外だけを追加する() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "shared確認前のpersonal installの終了コード"
  cp "$TARGET/.token-saver/installed.json" "$TEST_TMP/ledger.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "Codex所有権を読むshared installの終了コード"
  cmp -s "$TEST_TMP/ledger.before" "$TARGET/.token-saver/installed.json" ||
    _fail "shared installが台帳を変更した"
  assert_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" \
    "shared installのCodex作成所有権由来のmanaged除外"
}

test_Codexの構造不一致は再導入後も利用者hookと所有権を失わない() {
  local variant survived created dir_created
  TARGET="$TEST_TMP/target"
  for variant in stop matcher type limit missing-limit metadata duplicate; do
    rm -rf "$TARGET"
    _setup_target
    _run_install_args --personal
    assert_eq "0" "$INSTALL_STATUS" "${variant} fixtureの初回personal install"
    python3 - "$TARGET/.codex/hooks.json" "$variant" <<'PY'
import copy
import json
import sys

path, variant = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
group = next(group for group in data["hooks"]["SessionStart"] if any(
    "handoff-check.sh" in entry.get("command", "")
    for entry in group["hooks"]
))
entry = next(entry for entry in group["hooks"] if "handoff-check.sh" in entry.get("command", ""))
if variant == "stop":
    data["hooks"].setdefault("Stop", []).append({"hooks": [{
        "type": "command", "command": entry["command"]
    }]})
elif variant == "matcher":
    group["matcher"] = "other"
elif variant == "type":
    entry["type"] = "url"
elif variant == "limit":
    entry["additionalContextLimit"] = 9999
elif variant == "missing-limit":
    del entry["additionalContextLimit"]
elif variant == "metadata":
    group["description"] = "利用者が追加したgroup metadata"
elif variant == "duplicate":
    group["hooks"].append(copy.deepcopy(entry))
else:
    raise SystemExit("unknown variant: %s" % variant)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    _run_install_args --personal
    assert_eq "0" "$INSTALL_STATUS" "${variant} fixtureの再personal install"
    created="$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
      "$TARGET/.token-saver/installed.json" codex_hooks_created)"
    dir_created="$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
      "$TARGET/.token-saver/installed.json" codex_dir_created)"
    assert_eq "0" "$created" "${variant}のCodex hook作成所有権失効"
    assert_eq "0" "$dir_created" "${variant}の.codex作成所有権失効"
    survived="$(python3 - "$TARGET/.codex/hooks.json" "$variant" <<'PY'
import json
import sys

path, variant = sys.argv[1:]
with open(path, encoding="utf-8-sig") as handle:
    data = json.load(handle)
entries = [
    entry
    for groups in data.get("hooks", {}).values()
    if isinstance(groups, list)
    for group in groups
    if isinstance(group, dict) and isinstance(group.get("hooks"), list)
    for entry in group["hooks"]
    if isinstance(entry, dict) and "handoff-check.sh" in entry.get("command", "")
]
session = data.get("hooks", {}).get("SessionStart", [])
if variant == "stop":
    ok = any("handoff-check.sh" in entry.get("command", "")
             for group in data.get("hooks", {}).get("Stop", [])
             for entry in group.get("hooks", []))
elif variant == "matcher":
    ok = any(group.get("matcher") == "other" for group in session)
elif variant == "type":
    ok = any(entry.get("type") == "url" for entry in entries)
elif variant == "limit":
    ok = any(entry.get("additionalContextLimit") == 9999 for entry in entries)
elif variant == "missing-limit":
    ok = any("additionalContextLimit" not in entry for entry in entries)
elif variant == "metadata":
    ok = any(group.get("description") == "利用者が追加したgroup metadata" for group in session)
elif variant == "duplicate":
    ok = sum(1 for entry in entries if entry.get("type") == "command") >= 2
else:
    ok = False
print("yes" if ok else "no")
PY
)"
    assert_eq "yes" "$survived" "${variant}の利用者差し替えhook保持"
    _run_install_args --shared
    assert_eq "0" "$INSTALL_STATUS" "${variant} fixtureのshared install"
    assert_not_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" \
      "${variant}のmanaged Codex除外"
    bash "$REPO_ROOT/uninstall.sh" --personal "$TARGET" >/dev/null 2>&1 || true
    assert_file_exists "$TARGET/.codex/hooks.json" "${variant}の差し替え後hooks.json"
    assert_file_exists "$TARGET/.codex" "${variant}の差し替え後.codex"
    assert_file_exists "$TARGET/.token-saver/installed.json" "${variant}の取り残し台帳"
  done
}

test_Codexの同group別commandは所有権除外とremoveを維持する() {
  _setup_target
  _run_install_args --personal
  python3 - "$TARGET/.codex/hooks.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
for group in data["hooks"]["SessionStart"]:
    if any("handoff-check.sh" in entry.get("command", "") for entry in group["hooks"]):
        group["hooks"].append({"type": "command", "command": "echo 利用者hook"})
        break
with open(path, "w") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "同group別commandの再install"
  assert_eq "1" "$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
    "$TARGET/.token-saver/installed.json" codex_hooks_created)" "同group別commandのhook所有権"
  _run_install_args --shared
  assert_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" "同group別commandのmanaged除外"
  bash "$REPO_ROOT/uninstall.sh" --personal "$TARGET" >/dev/null 2>&1 || true
  assert_file_exists "$TARGET/.codex/hooks.json" "同group別commandのhooks.json"
  assert_contains "$(cat "$TARGET/.codex/hooks.json")" "echo 利用者hook" \
    "同group利用者hookの保持"
  assert_not_contains "$(cat "$TARGET/.codex/hooks.json")" "handoff-check.sh" \
    "同group managed hookのremove"
}

test_旧台帳のCodex所有フラグを移行後に読み直してuninstallできる() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "legacy fixtureの初回personal install"
  mkdir -p "$TARGET/.claude/.token-saver"
  mv "$TARGET/.token-saver/installed.json" "$TARGET/.claude/.token-saver/installed.json"
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "legacy-only migrationのpersonal install"
  assert_file_exists "$TARGET/.token-saver/installed.json" "移行後の新台帳"
  assert_file_missing "$TARGET/.claude/.token-saver/installed.json" "移行後の旧台帳"
  assert_eq "1" "$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
    "$TARGET/.token-saver/installed.json" codex_hooks_created)" "移行後Codex hook所有権"
  assert_eq "1" "$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
    "$TARGET/.token-saver/installed.json" codex_dir_created)" "移行後.codex所有権"
  _run_install_args --shared
  assert_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" "移行後sharedのCodex除外"
  bash "$REPO_ROOT/uninstall.sh" "$TARGET" >/dev/null 2>&1 || true
  assert_file_missing "$TARGET/.codex/hooks.json" "移行後uninstallのhooks.json"
  assert_file_missing "$TARGET/.codex" "移行後uninstallの.codex"
}

test_新旧台帳競合では新台帳だけを権威にする() {
  _setup_target
  _run_install_args --personal
  mkdir -p "$TARGET/.claude/.token-saver"
  cp "$TARGET/.token-saver/installed.json" "$TARGET/.claude/.token-saver/installed.json"
  python3 "$REPO_ROOT/lib/ledger.py" set-flag "$TARGET/.token-saver/installed.json" \
    codex_hooks_created 0 >/dev/null
  python3 "$REPO_ROOT/lib/ledger.py" set-flag "$TARGET/.token-saver/installed.json" \
    codex_dir_created 0 >/dev/null
  cp "$TARGET/.claude/.token-saver/installed.json" "$TEST_TMP/legacy.before"
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "新旧台帳競合のinstall終了コード"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "新旧" "新旧台帳競合の警告"
  assert_eq "0" "$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
    "$TARGET/.token-saver/installed.json" codex_hooks_created)" "新台帳のCodex flags"
  assert_eq "0" "$(python3 "$REPO_ROOT/lib/ledger.py" get-flag \
    "$TARGET/.token-saver/installed.json" codex_dir_created)" "新台帳の.codex flags"
  cmp -s "$TEST_TMP/legacy.before" "$TARGET/.claude/.token-saver/installed.json" ||
    _fail "競合時に旧台帳を変更した"
  _run_install_args --shared
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".codex/hooks.json" \
    "新台帳false時のCodex除外"
}

test_shared専用は新旧台帳をbyte単位で変更しない() {
  _setup_target
  _run_install_args --personal
  mkdir -p "$TARGET/.claude/.token-saver"
  cp "$TARGET/.token-saver/installed.json" "$TARGET/.claude/.token-saver/installed.json"
  cp "$TARGET/.token-saver/installed.json" "$TEST_TMP/new.before"
  cp "$TARGET/.claude/.token-saver/installed.json" "$TEST_TMP/legacy.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "shared-onlyの終了コード"
  cmp -s "$TEST_TMP/new.before" "$TARGET/.token-saver/installed.json" ||
    _fail "shared-onlyが新台帳を変更した"
  cmp -s "$TEST_TMP/legacy.before" "$TARGET/.claude/.token-saver/installed.json" ||
    _fail "shared-onlyが旧台帳を変更した"
}

test_既存の_settings_をバックアップする() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  assert_file_exists "$SETTINGS.cts-backup"
  assert_contains "$(cat "$SETTINGS.cts-backup")" "Bash(ls:*)" "バックアップの内容"
  assert_contains "$INSTALL_OUT" "cts-backup" "出力"
}

test_バックアップは二度目の実行で上書きしない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  _run_install
  assert_contains "$(cat "$SETTINGS.cts-backup")" "Bash(ls:*)" "バックアップの内容"
  assert_not_contains "$(cat "$SETTINGS.cts-backup")" "handoff-check.sh" "バックアップの内容"
}

test_settings_に変化が無ければ書き込まない() {
  _setup_target
  _run_install
  touch -t 202001010000 "$SETTINGS"
  local before after
  _require_mtime "$SETTINGS"
  # runner-allow: 取得可能性を先に確認した上で、mtime値を比較するために捕捉する。
  before="$(_mtime "$SETTINGS")"
  _run_install
  # runner-allow: 取得可能性を先に確認した上で、mtime値を比較するために捕捉する。
  after="$(_mtime "$SETTINGS")"
  assert_eq "$before" "$after" "settings.local.json の mtime"
}

test_設置したものを台帳へ記録する() {
  _setup_target
  _run_install
  # 「何を設置したか」を記録していないと、uninstall が推測で判定するしかなくなる。
  local led
  led="$(cat "$TARGET/.token-saver/installed.json")"
  assert_contains "$led" "session-handoff" "台帳"
  assert_contains "$led" "handoff-check.sh" "台帳"
}

test_クローンに__pycache__を書き散らさない() {
  _setup_target
  local clone="$TEST_TMP/clone"
  # 作業ツリー側の誤残を持ち込ませないことと、install 実行後に生成しないことの両方を見る。
  mkdir -p "$REPO_ROOT/lib/__pycache__"
  printf 'pollute\n' >"$REPO_ROOT/lib/__pycache__/cts-test-pollute.pyc"
  # 失敗時も残さない。並列実行では各ランナーが別 repo root を持つ前提である。
  trap 'rm -rf "$REPO_ROOT/lib/__pycache__"' RETURN
  _clone_repo "$clone"
  assert_file_missing "$clone/lib/__pycache__" "clone へ持ち込まない"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  # 導入先から呼ばれる道具である。利用者のクローンに生成物を残さない。
  assert_file_missing "$clone/lib/__pycache__" "install 後も生成しない"
}

test_利用者が張った同名スキルのリンクは上書きしない() {
  _setup_target
  # 導入先が自分の共有ディレクトリへ張ったリンク。実ディレクトリでないという
  # だけで rm -rf すると、他人の設置物を黙って消す。
  mkdir -p "$TEST_TMP/shared/skills/session-handoff"
  printf '利用者の共有スキル\n' >"$TEST_TMP/shared/skills/session-handoff/SKILL.md"
  mkdir -p "$TARGET/.claude/skills"
  ln -s "$TEST_TMP/shared/skills/session-handoff" "$TARGET/.claude/skills/session-handoff"
  _run_install
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "利用者の共有スキル" "スキルの内容"
  assert_contains "$INSTALL_OUT" "警告" "出力"
}

test_書き戻したファイルのパーミッションを保つ() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  chmod 644 "$TARGET/.gitignore"
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  chmod 644 "$SETTINGS"
  _run_install
  # .gitignore は追跡ファイルである。0600 に落とすと共有ワークツリーや CI で読めなくなる。
  assert_eq "644" "$(_perm "$TARGET/.gitignore")" ".gitignore のパーミッション"
  assert_eq "644" "$(_perm "$SETTINGS")" "settings.local.json のパーミッション"
}

test_新規作成するファイルは_umask_に従う() {
  _setup_target
  ( umask 022; bash "$INSTALL" "$TARGET" >/dev/null 2>&1 )
  assert_eq "644" "$(_perm "$TARGET/.gitignore")" ".gitignore のパーミッション"
  assert_eq "644" "$(_perm "$SETTINGS")" "settings.local.json のパーミッション"
}

test_settings_の書式は内容が同値なら保つ() {
  _setup_target
  _run_install
  # 利用者が自分の書式へ整え直した状態を模す。登録内容が変わらないのに
  # 再整形するのは、利用者のファイルを黙って書き換えることである。
  python3 -c '
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
with open(p, "w") as f:
    f.write(json.dumps(d, ensure_ascii=False, indent=4) + "\n")
' "$SETTINGS"
  local before
  before="$(cat "$SETTINGS")"
  _run_install
  assert_eq "$before" "$(cat "$SETTINGS")" "settings.local.json"
}

test_gitignore_のブロックが2つあれば1つに畳む() {
  _setup_target
  {
    printf '%s\n.claude/.handoff/\n%s\n' "$GITIGNORE_START" "$GITIGNORE_END"
    printf '%s\n.claude/.handoff/\n%s\n' "$GITIGNORE_START" "$GITIGNORE_END"
  } >"$TARGET/.gitignore"
  _run_install
  # 別クローンからの旧 install やマージ衝突の両採用で容易に生じる。
  # 片方を残すと、uninstall がそれを永久に取り残す。
  assert_count 1 "$(cat "$TARGET/.gitignore")" "$GITIGNORE_END" "END マーカー"
  assert_count 1 "$(cat "$TARGET/.gitignore")" "$GITIGNORE_START" "START マーカー"
}

test_クローンが不完全なら警告して完了と言わない() {
  _setup_target
  local clone="$TEST_TMP/broken"
  _clone_repo "$clone"
  # scripts/lib/paths.sh は install.sh 自体が動くための必須基盤なので、
  # ここを消すと警告ではなく即エラー終了になる。ここで見たいのは
  # 「フック・スキルが欠けている程度の不完全さ」であって、
  # install.sh を実行不能にする破損ではない。
  rm -rf "$clone/scripts/handoff-check.sh" "$clone/skills"
  bash "$clone/install.sh" "$TARGET" >"$TEST_TMP/.out" 2>&1
  local out
  out="$(cat "$TEST_TMP/.out")"
  assert_contains "$out" "警告" "出力"
  assert_not_contains "$out" "完了。" "出力"
}

test_gitignore_の警告はマーカー文字列と行番号を示す() {
  _setup_target
  printf 'dist/\n%s\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  _run_install
  # 「手で直せ」と言うなら、直す手掛かりを出さねば従えない。
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "$GITIGNORE_END" "出力"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "2 行目" "出力"
}

test_利用者の空のフックイベントを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"hooks":{"Stop":[]}}\n' >"$SETTINGS"
  _run_install
  # 明示的な空は「何も登録しない」という設定意図である。
  assert_contains "$(cat "$SETTINGS")" '"Stop"' "settings.local.json"
}

test_CTS_STRICT_なら警告で非ゼロを返す() {
  _setup_target
  printf 'dist/\n%s\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  local rc=0
  CTS_STRICT=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "終了コード"
}

test_警告があればサマリで再掲する() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/session-handoff"
  printf '導入先が自分で書いたもの\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  _run_install
  # 「完了」とだけ出して警告を流すと、利用者は取りこぼしに気づけない。
  assert_contains "$INSTALL_OUT" "警告" "出力"
  local tail_out
  tail_out="$(printf '%s\n' "$INSTALL_OUT" | tail -n 5)"
  assert_contains "$tail_out" "警告" "出力の末尾"
}

# --- 既存物の種類を見落とす経路 ----------------------------------------------

test_同名の通常ファイルがあれば触らず警告する() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills"
  printf '利用者のメモ\n' >"$TARGET/.claude/skills/session-handoff"
  _run_install
  # 分岐がリンクとディレクトリしか見ていないと、これが rm -rf へ落ちて
  # 利用者のファイルを無警告で消す。
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff")" "利用者のメモ" "既存ファイル"
  assert_contains "$INSTALL_OUT" "警告" "出力"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignore"
}

# --- 途中で失敗したときの控えの案内 ------------------------------------------

test_die_しても控えの場所を伝える() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  # 控えは settings.local.json の書き換えより前に作られるため、この後で
  # die しても残る。案内しなければ利用者は残ったことを知らない。
  printf '{"permissions":{"allow":["Bash(ls:*)"]},\n' >"$SETTINGS"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$SETTINGS.cts-backup"
  assert_contains "$INSTALL_ERR" "cts-backup" "標準エラー"
}

test_控えは再実行で自分の書いた内容へ塗り替えない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  _run_install
  # 控えの値打ちは「導入より前の内容」であることに尽きる。
  assert_not_contains "$(cat "$SETTINGS.cts-backup")" "handoff-check.sh" "控えの内容"
  assert_contains "$(cat "$SETTINGS.cts-backup")" "Bash(ls:*)" "控えの内容"
}

# --- 台帳の行プロトコルと書き込み失敗 ----------------------------------------

test_台帳は行プロトコルに載せられない名前を拒む() {
  local led="$TEST_TMP/led.json" rc
  # TSV の行プロトコルは tab と改行を表現できない。JSON は表現できるという
  # 不整合を放置すると、別名のスキルを対象にしたり .gitignore へ2行生成できる。
  local bad
  for bad in "$(printf 'a\tb')" "$(printf 'a\nb')" "../outside" ".." "sub/dir" ""; do
    rc=0
    python3 "$REPO_ROOT/lib/ledger.py" add-skill "$led" "$bad" /src link >/dev/null 2>&1 || rc=$?
    assert_ne "0" "$rc" "名前=[$bad] の終了コード"
  done
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" add-skill "$led" "session-handoff" /src link >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "妥当な名前の終了コード"
}

test_台帳は行プロトコルに載らない記録を読み飛ばす() {
  local led="$TEST_TMP/led.json" out
  # tab を含む名前は、渡した先で境界が壊れる（別名のスキルを対象にできる）。
  # 渡すこと自体ができないので、読む側で落とす。
  printf '%s' '{"skills":[{"name":"a\tb","src":"/s","mode":"link"},{"name":"ok","src":"/s","mode":"link"}]}' >"$led"
  out="$(python3 "$REPO_ROOT/lib/ledger.py" list-skills "$led" 2>/dev/null)"
  assert_not_contains "$out" "a	b" "list-skills の出力"
  assert_contains "$out" "ok" "list-skills の出力"
}

test_台帳の行プロトコルは空のフィールドを保つ() {
  local led="$TEST_TMP/led.json" got
  printf '%s' '{"skills":[{"name":"ok","src":"","mode":"link"}]}' >"$led"
  # tab 区切りだと、読む側の IFS が連続する区切りを畳んで src が mode の値に
  # 化ける。「記録が欠けている」ことが別の値として読まれてはならない。
  got="$(python3 "$REPO_ROOT/lib/ledger.py" list-skills "$led" |
    { IFS=$'\037' read -r n s m; printf 'n=[%s] s=[%s] m=[%s]' "$n" "$s" "$m"; })"
  assert_eq "n=[ok] s=[] m=[link]" "$got" "list-skills の行"
}

test_台帳の記録の有無をファイルの有無と区別する() {
  local led="$TEST_TMP/led.json" rc
  local variant
  for variant in '{}' 'null' '[]' '"x"' '' 'not json'; do
    printf '%s' "$variant" >"$led"
    rc=0
    python3 "$REPO_ROOT/lib/ledger.py" has-record "$led" any || rc=$?
    assert_ne "0" "$rc" "台帳=[$variant] は記録なしと判定されねばならない"
  done
  python3 "$REPO_ROOT/lib/ledger.py" add-skill "$led" ok /src link >/dev/null 2>&1
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record "$led" skills || rc=$?
  assert_eq "0" "$rc" "記録のある台帳"
  # 空の hooks リストは「登録すべきものが無かった」という記録である。
  printf '%s' '{"hooks":[]}' >"$led"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record "$led" hooks || rc=$?
  assert_eq "0" "$rc" "空の hooks リスト"
}

test_台帳を書けない場所でもトレースバックを出さない() {
  # ディレクトリを作れない場所を作る（root でも失敗する形にする）。
  printf 'x\n' >"$TEST_TMP/notadir"
  local led="$TEST_TMP/notadir/installed.json" out rc=0
  out="$(python3 "$REPO_ROOT/lib/ledger.py" add-skill "$led" ok /src link 2>&1)" || rc=$?
  assert_ne "0" "$rc" "ledger.py の終了コード"
  assert_not_contains "$out" "Traceback" "ledger.py の出力"
  assert_contains "$out" "台帳" "ledger.py の出力"

  # settings-hooks.py 経由の ledger.save は捕まえていなかった経路である。
  _setup_target
  rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$led" "SessionStart:$REPO_ROOT/scripts/handoff-check.sh" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "settings-hooks.py の終了コード"
  assert_not_contains "$out" "Traceback" "settings-hooks.py の出力"
  # 何が書けなかったのかを名指しすること。総括の捕捉だけに任せると
  # 「ファイルを操作できない」としか言わず、原因の切り分けができない。
  assert_contains "$out" "台帳を書けない" "settings-hooks.py の出力"
}

test_gitignore_を書けない場所でもトレースバックを出さない() {
  printf 'x\n' >"$TEST_TMP/notadir"
  local out rc=0
  out="$(printf '.claude/.handoff/\n' |
    python3 "$REPO_ROOT/lib/gitignore-block.py" apply "$TEST_TMP/notadir/.gitignore" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "終了コード"
  assert_not_contains "$out" "Traceback" "出力"
}

test_START_が2つあれば追記せず警告する() {
  _setup_target
  {
    printf '%s\n' "$GITIGNORE_START"
    printf '利用者の行A\n'
    printf '%s\n' "$GITIGNORE_START"
    printf '.claude/.handoff/\n'
    printf '%s\n' "$GITIGNORE_END"
  } >"$TARGET/.gitignore"
  local before
  before="$(cat "$TARGET/.gitignore")"
  _run_install
  # 対の揃わない START を区間の内側として飲み込むと、利用者の行が消える。
  assert_eq "$before" "$(cat "$TARGET/.gitignore")" ".gitignore"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "警告" "出力"
}

test_台帳無しのinstallは推測候補を消さず警告する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TEST_TMP/old/scripts"
  : >"$TEST_TMP/old/scripts/handoff-check.sh"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "$TEST_TMP/old/scripts/handoff-check.sh" >"$SETTINGS"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$(_hook_commands SessionStart)" "$TEST_TMP/old/scripts/handoff-check.sh" \
    "推測候補である利用者のフック"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "推測" "推測候補の警告"
}

test_インストールの重複スコープを変更前に拒否する() {
  _setup_target
  printf '利用者の除外\n' >"$TARGET/.gitignore"
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_install_args --personal --shared
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail "不正なスコープ指定で.gitignoreが変更された"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "スコープ" "エラー"
}

test_personalスコープは_gitignoreを変更しない() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail "--personal が.gitignoreを変更した"
  assert_file_exists "$SETTINGS" "settings.local.json"
  assert_file_exists "$TARGET/.claude/skills/session-handoff" "スキル"
  assert_file_exists "$TARGET/.token-saver/installed.json" "台帳"
}

test_personalスコープは_gitignoreを新規作成しない() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.gitignore" "--personal後の.gitignore"
  assert_file_exists "$SETTINGS" "settings.local.json"
  assert_file_exists "$TARGET/.token-saver/installed.json" "台帳"
}

test_personalスコープの完了メッセージは共有更新手順を案内する() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" ".gitignore は変更していない" \
    "--personalの完了メッセージ"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "--shared" \
    "--personalの共有更新案内"
}

test_sharedスコープは個人の設置物を変更せず_台帳のスキルだけ除外する() {
  _setup_target
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "personalの終了コード"
  cp "$SETTINGS" "$TEST_TMP/settings.before"
  cp "$TARGET/.token-saver/installed.json" "$TEST_TMP/ledger.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "sharedの終了コード"
  cmp -s "$TEST_TMP/settings.before" "$SETTINGS" ||
    _fail "--shared がsettings.local.jsonを変更した"
  cmp -s "$TEST_TMP/ledger.before" "$TARGET/.token-saver/installed.json" ||
    _fail "--shared が台帳を変更した"
  assert_contains "$(cat "$TARGET/.gitignore")" ".token-saver/" ".gitignore"
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignore"
}

test_sharedスコープの完了メッセージはフック導入を示さない() {
  _setup_target
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" \
    "完了。共有設定（.gitignore）を更新した。" "--sharedの完了メッセージ"
  assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "引き継ぎフックが有効" \
    "--sharedの完了メッセージ"
}

test_sharedスコープは台帳が無ければ推測しない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/session-handoff"
  printf '利用者のスキル\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  printf '{"permissions":{}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$TEST_TMP/settings.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.token-saver/installed.json" "台帳"
  assert_file_exists "$TARGET/.claude/skills/session-handoff/SKILL.md" "既存スキル"
  cmp -s "$TEST_TMP/settings.before" "$SETTINGS" ||
    _fail "--shared がsettings.local.jsonを変更した"
  assert_contains "$(cat "$TARGET/.gitignore")" ".token-saver/" ".gitignore"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignoreの推測除外"
}

test_sharedスコープは旧台帳を読み取り実所有スキルだけを除外し移行しない() {
  _setup_target
  # 旧台帳の記録だけでなく、実配置も自分のリンクである場合に限って除外する。
  mkdir -p "$TARGET/.claude/skills"
  ln -s "$REPO_ROOT/skills/session-handoff" "$TARGET/.claude/skills/session-handoff"
  mkdir -p "$TARGET/.claude/.token-saver"
  python3 - "$TARGET/.claude/.token-saver/installed.json" "$REPO_ROOT/skills/session-handoff" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as handle:
    json.dump({"skills": [{"name": "session-handoff", "src": sys.argv[2], "mode": "link"}]}, handle)
    handle.write("\n")
PY
  cp "$TARGET/.claude/.token-saver/installed.json" "$TEST_TMP/legacy-ledger.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.token-saver/installed.json" "共有専用で作られた新台帳"
  cmp -s "$TEST_TMP/legacy-ledger.before" "$TARGET/.claude/.token-saver/installed.json" ||
    _fail "--shared が旧台帳を変更または移行した"
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" ".gitignore"
}

test_sharedスコープは再実行で_gitignoreを再書き込みしない() {
  _setup_target
  _run_install_args --personal
  _run_install_args --shared
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail "sharedの再実行で.gitignoreが変化した"
}

test_sharedスコープは複数クローンで個別の台帳を読む() {
  local first="$TEST_TMP/target-first" second="$TEST_TMP/target-second"
  mkdir -p "$first" "$second"
  ( cd "$first" && git init -q . )
  ( cd "$second" && git init -q . )

  TARGET="$first"
  SETTINGS="$TARGET/.claude/settings.local.json"
  _run_install_args --personal
  assert_eq "0" "$INSTALL_STATUS" "first personalの終了コード"

  TARGET="$second"
  SETTINGS="$TARGET/.claude/settings.local.json"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "second sharedの終了コード"
  assert_file_missing "$SETTINGS" "secondのsettings"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" "secondの推測除外"

  TARGET="$first"
  SETTINGS="$TARGET/.claude/settings.local.json"
  _run_install_args --shared
  assert_eq "0" "$INSTALL_STATUS" "first sharedの終了コード"
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" "firstの台帳由来除外"
}

test_sharedスコープは_gitignoreのシンボリックリンクを変更しない() {
  _setup_target
  printf '利用者の設定\n' >"$TEST_TMP/real.gitignore"
  ln -s "$TEST_TMP/real.gitignore" "$TARGET/.gitignore"
  _run_install_args --shared
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  if [ ! -L "$TARGET/.gitignore" ]; then
    _fail "--shared が.gitignoreのシンボリックリンクを置き換えた"
  fi
  assert_eq "利用者の設定" "$(cat "$TEST_TMP/real.gitignore")" "リンク先の内容"
}

test_インストール引数の不正値を拒否する() {
  local out rc=0
  out="$(bash "$INSTALL" --help 2>&1)" || rc=$?
  assert_eq "0" "$rc" "--help の終了コード"
  assert_contains "$out" "usage:" "--help の出力"
  assert_contains "$out" "--personal" "--help の個人スコープ"
  assert_contains "$out" "--shared" "--help の共有スコープ"

  rc=0
  out="$(bash "$INSTALL" -P 2>&1)" || rc=$?
  assert_ne "0" "$rc" "-P の終了コード"
  assert_contains "$out" "オプション" "-P の出力"

  _setup_target
  rc=0
  out="$(bash "$INSTALL" "$TARGET" "$TARGET" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "余分な引数の終了コード"
}

test_既存_gitignoreの改行形式と末尾改行を往復で保つ() {
  _setup_target
  printf 'node_modules/\r\ndist/' >"$TARGET/.gitignore"
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_install
  bash "$REPO_ROOT/uninstall.sh" "$TARGET" >/dev/null 2>&1
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail ".gitignore の CRLF と末尾改行が往復で変わった"
}

test_BOM付き設定と非UTF8_gitignoreをトレースバック無しで扱う() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  python3 - "$SETTINGS" <<'PY'
import sys
path = sys.argv[1]
with open(path, "wb") as f:
    f.write(b"\xef\xbb\xbf{\"permissions\":{}}\n")
PY
  printf 'node_modules/\377\n' >"$TARGET/.gitignore"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "BOM/非UTF-8時の終了コード"
  assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "Traceback" "BOM/非UTF-8時の出力"
  python3 - "$SETTINGS" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as f:
    json.load(f)
PY
}

test_既存の正しいリンクも_CTS_NO_SYMLINKでコピーへ切り替える() {
  _setup_target
  _run_install
  if [ ! -L "$TARGET/.claude/skills/session-handoff" ]; then
    _fail "初回インストールでスキルのリンクが作られていない"
  fi
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  if [ -L "$TARGET/.claude/skills/session-handoff" ]; then
    _fail "CTS_NO_SYMLINK=1 で既存リンクが残った"
  fi
  assert_file_exists "$TARGET/.claude/skills/session-handoff/.claude-token-saver"
}

test_旧パスのコンテナシンボリックリンクを辿らない() {
  _setup_target
  mkdir -p "$TEST_TMP/outside"
  printf '外部の記録\n' >"$TEST_TMP/outside/a.md"
  mkdir -p "$TARGET/.claude/.handoff"
  ln -s "$TEST_TMP/outside" "$TARGET/.claude/.handoff/pending"
  _run_install
  assert_file_exists "$TEST_TMP/outside/a.md" "外部ディレクトリのファイル"
  if [ ! -L "$TARGET/.claude/.handoff/pending" ]; then
    _fail "旧パスのコンテナシンボリックリンクを置き換えた"
  fi
}

test_シンボリックリンクの_gitignoreを置き換えない() {
  _setup_target
  printf '利用者の設定\n' >"$TEST_TMP/real.gitignore"
  ln -s "$TEST_TMP/real.gitignore" "$TARGET/.gitignore"
  local out rc=0
  out="$(printf '.token-saver/\n' | python3 "$REPO_ROOT/lib/gitignore-block.py" apply "$TARGET/.gitignore" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "シンボリックリンクへの終了コード"
  if [ ! -L "$TARGET/.gitignore" ]; then
    _fail ".gitignore のシンボリックリンクを実体へ置き換えた"
  fi
  assert_eq "利用者の設定" "$(cat "$TEST_TMP/real.gitignore")" "リンク先の内容"
  assert_not_contains "$out" "Traceback" "シンボリックリンクへの出力"
}

test_シンボリックリンクの_settingsを置き換えない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{}}\n' >"$TEST_TMP/real.settings"
  ln -s "$TEST_TMP/real.settings" "$SETTINGS"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "settings シンボリックリンクへの終了コード"
  if [ ! -L "$SETTINGS" ]; then
    _fail "settings.local.json のシンボリックリンクを実体へ置き換えた"
  fi
  assert_eq '{"permissions":{}}' "$(cat "$TEST_TMP/real.settings")" "settings リンク先の内容"
}

test_不正なフック構造と引数をトレースバック無しで拒否する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver"
  printf '{"hooks":{"SessionStart":"配列ではない"}}\n' >"$SETTINGS"
  local out rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$TARGET/.token-saver/installed.json" "SessionStart:$REPO_ROOT/scripts/handoff-check.sh" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "不正な hooks 構造の終了コード"
  assert_not_contains "$out" "Traceback" "不正な hooks 構造の出力"

  rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --bogus "SessionStart:$REPO_ROOT/scripts/handoff-check.sh" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "不明な引数の終了コード"
  assert_not_contains "$out" "Traceback" "不明な引数の出力"
}

test_読み取り専用の設定をatomic書き込みで置き換えない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$TEST_TMP/settings.before"
  # rootで実行すると所有者権限により444でも書き込み・置換が成功し得る。
  # このテストの読み取り専用検証は、通常ユーザーの権限で実行した結果を前提とする。
  chmod 444 "$SETTINGS"
  _run_install
  chmod 644 "$SETTINGS" 2>/dev/null || true
  assert_ne "0" "$INSTALL_STATUS" "読み取り専用 settings の終了コード"
  cmp -s "$TEST_TMP/settings.before" "$SETTINGS" || _fail "読み取り専用 settings を変更した"
  assert_file_missing "$SETTINGS.cts-backup" "失敗時に残る settings の控え"
  assert_file_missing "$TARGET/.token-saver/installed.json" "失敗時に残る台帳"
  assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "Traceback" "読み取り専用 settings の出力"
}

test_管理対象親ディレクトリのシンボリックリンクを辿らない() {
  _setup_target
  mkdir -p "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.token-saver"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "管理対象親ディレクトリの終了コード"
  assert_file_missing "$TEST_TMP/outside/handoff" "外部の引き継ぎディレクトリ"
  assert_file_missing "$TEST_TMP/outside/installed.json" "外部の台帳"
  assert_not_contains "$INSTALL_OUT$INSTALL_ERR" "Traceback" "管理対象親ディレクトリの出力"
}

test_token_reportの導入先entrypointが対象repoへレポートを書く() {
  _setup_target
  config="$TEST_TMP/claude-config"
  home="$TEST_TMP/report-home"
  mkdir -p "$config/projects" "$home"
  project_key="$(printf '%s' "$TARGET" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$config/projects/$project_key"
  python3 - "$config/projects/$project_key/session.jsonl" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone

row = {
    "type": "assistant",
    "timestamp": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "message": {
        "id": "installed-entrypoint",
        "model": "claude-install-fixture",
        "usage": {"input_tokens": 1, "cache_creation_input_tokens": 10,
                  "cache_read_input_tokens": 100, "output_tokens": 1},
        "content": [],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(row) + "\n")
PYEOF
  before_source_reports="$(find "$REPO_ROOT/.token-saver/token-reports" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)"
  before_source_status="$(git -C "$REPO_ROOT" status --short)"
  _run_install
  entrypoint="$TARGET/.token-saver/token-report.sh"
  assert_eq "0" "$INSTALL_STATUS" "install終了コード"
  assert_file_exists "$entrypoint" "導入先entrypoint"
  [ -x "$entrypoint" ] || _fail "導入先entrypointに実行権限がない"

  (
    cd "$TEST_TMP" &&
    HOME="$home" CLAUDE_CONFIG_DIR="$config" bash "$entrypoint" --days 0
  ) >"$TEST_TMP/report.out" 2>"$TEST_TMP/report.err"
  report_status=$?
  reports="$(find "$TARGET/.token-saver/token-reports" -maxdepth 1 -type f -name '*.md' -print)"
  report_count="$(printf '%s\n' "$reports" | sed '/^$/d' | wc -l | tr -d ' ')"
  after_source_reports="$(find "$REPO_ROOT/.token-saver/token-reports" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort)"
  after_source_status="$(git -C "$REPO_ROOT" status --short)"
  assert_eq "0" "$report_status" "導入済みentrypoint終了コード"
  assert_eq "1" "$report_count" "導入先のレポート件数"
  assert_contains "$(cat "$reports")" "main 合計: **112**" "導入先repoの集計"
  assert_eq "$before_source_reports" "$after_source_reports" "helper clone側のレポート一覧"
  assert_eq "$before_source_status" "$after_source_status" "helper clone側のworktree状態"
  assert_count 1 "$(cat "$TEST_TMP/report.out")" "書き出しました:" "成功メッセージ"
}

test_token_calibrate_sourceを台帳へ保存する() {
  _setup_target
  mkdir -p "$TARGET/.token-saver"
  ledger="$TARGET/.token-saver/installed.json"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" set-value "$ledger" token_calibrate_source \
    "$REPO_ROOT/scripts/token-calibrate.sh" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "token_calibrate_source保存"
  value="$(python3 "$REPO_ROOT/lib/ledger.py" get-value "$ledger" token_calibrate_source)"
  assert_eq "$REPO_ROOT/scripts/token-calibrate.sh" "$value" "token_calibrate_source読出し"
}

test_token_calibrateの導入先entrypointが対象repoへ適用する() {
  _setup_target
  _write_calibration_fixture
  _run_install
  entrypoint="$TARGET/.token-saver/token-calibrate.sh"
  assert_eq "0" "$INSTALL_STATUS" "token-calibrate install終了コード"
  assert_file_exists "$entrypoint" "token-calibrate導入先entrypoint"
  [ -x "$entrypoint" ] || _fail "token-calibrate entrypointに実行権限がない"
  ledger_text="$(cat "$TARGET/.token-saver/installed.json")"
  assert_contains "$ledger_text" 'token_calibrate_source' "token-calibrate台帳キー"
  assert_contains "$ledger_text" "$REPO_ROOT/scripts/token-calibrate.sh" "token-calibrate台帳source"
  (
    export CLAUDE_CONFIG_DIR="$CALIBRATION_CLAUDE_CONFIG_DIR"
    cd "$TEST_TMP" &&
    bash "$entrypoint" --apply
  ) >"$TEST_TMP/calibrate-install.out" 2>"$TEST_TMP/calibrate-install.err"
  apply_status=$?
  applied_initial="$(python3 - "$CALIBRATION_CONFIG" <<'PYEOF'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["suggest_session_cut"]["initial_cache_read"])
PYEOF
)"
  assert_eq "0" "$apply_status" "導入済みtoken-calibrate実行"
  assert_eq "18000000" "$applied_initial" "導入済みentrypointの対象root"
}

test_token_calibrateの既存entrypointを差し替えない() {
  _setup_target
  mkdir -p "$TARGET/.token-saver"
  entrypoint="$TARGET/.token-saver/token-calibrate.sh"
  printf '#!/usr/bin/env bash\nprintf "利用者のentrypoint\\n"\n' >"$entrypoint"
  _run_install
  assert_file_exists "$entrypoint" "既存token-calibrate entrypoint"
  assert_contains "$(cat "$entrypoint")" "利用者のentrypoint" "既存entrypoint内容"
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "token-calibrate" "既存entrypoint警告"
}

test_混在改行の_gitignoreは往復で変更しない() {
  _setup_target
  printf 'a\r\nb\nc' >"$TARGET/.gitignore"
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_install
  bash "$REPO_ROOT/uninstall.sh" "$TARGET" >/dev/null 2>&1
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail "混在改行の .gitignore を往復で変更した"
}


# --- Issue #38: namespaced slash commands (directory package) -----------------

test_スラッシュコマンドパッケージをリンクする() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  [ -L "$TARGET/.claude/commands/token-saver" ] ||
    _fail "commands/token-saver がシンボリックリンクではない"
  assert_eq "$REPO_ROOT/commands/token-saver" \
    "$(readlink "$TARGET/.claude/commands/token-saver")" "コマンドリンク先"
  assert_file_exists "$TARGET/.claude/commands/token-saver/report.md"
  assert_file_exists "$TARGET/.claude/commands/token-saver/calibrate.md"
  assert_file_exists "$TARGET/.claude/commands/token-saver/suggest-session-cut.md"
}


test_スラッシュコマンド定義は薄いentrypoint指示である() {
  local body
  body="$(cat "$REPO_ROOT/commands/token-saver/report.md")"
  assert_contains "$body" "./.token-saver/token-report.sh" "report entrypoint"
  assert_not_contains "$body" "measure-token-usage.py" "report に計測本体を埋め込まない"

  body="$(cat "$REPO_ROOT/commands/token-saver/calibrate.md")"
  assert_contains "$body" "./.token-saver/token-calibrate.sh --apply" "calibrate entrypoint"
  assert_not_contains "$body" "apply_token_calibration" "calibrate に適用ロジックを埋め込まない"

  body="$(cat "$REPO_ROOT/commands/token-saver/suggest-session-cut.md")"
  assert_contains "$body" "suggest-session-cut.sh" "suggest-session-cut 実体"
  assert_not_contains "$body" "def " "suggest-session-cut に Python 定義を埋め込まない"
}

test_スラッシュコマンドを台帳とgitignoreへ記録する() {
  _setup_target
  _run_install
  ledger="$(cat "$TARGET/.token-saver/installed.json")"
  assert_contains "$ledger" '"name": "token-saver"' "台帳 name"
  assert_contains "$ledger" '"commands"' "台帳 commands キー"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/commands/token-saver" ".gitignore"
  rc=0
  python3 "$REPO_ROOT/lib/ledger.py" has-record \
    "$TARGET/.token-saver/installed.json" commands || rc=$?
  assert_eq "0" "$rc" "has-record commands"
}

test_スラッシュコマンドをコピー配置できる() {
  _setup_target
  local status=0
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >"$TEST_TMP/.out" 2>&1 || status=$?
  assert_eq "0" "$status" "終了コード"
  [ ! -L "$TARGET/.claude/commands/token-saver" ] ||
    _fail "CTS_NO_SYMLINK でもシンボリックリンクになっている"
  assert_file_exists "$TARGET/.claude/commands/token-saver/report.md"
  assert_file_exists "$TARGET/.claude/commands/token-saver/.claude-token-saver"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/commands/token-saver" ".gitignore"
}

test_利用者の同名コマンドディレクトリは触らない() {
  _setup_target
  mkdir -p "$TARGET/.claude/commands/token-saver"
  printf '利用者のコマンド\n' >"$TARGET/.claude/commands/token-saver/report.md"
  _run_install
  assert_contains "$(cat "$TARGET/.claude/commands/token-saver/report.md")" \
    "利用者のコマンド" "同名保護"
  assert_not_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/commands/token-saver" ".gitignore"
}

test_スラッシュコマンドを_agentsへ置かない() {
  _setup_target
  _run_install
  assert_file_missing "$TARGET/.agents/commands"
  assert_file_missing "$TARGET/.agents/commands/token-saver"
}

test_Claudeのlegacy風コマンドリンクを現srcへ張り替える() {
  _setup_target
  old_repo="$TEST_TMP/old-repo"
  old_link="$old_repo/commands/token-saver"
  mkdir -p "$old_link" "$old_repo/lib" "$TARGET/.claude/commands"
  printf '#!/usr/bin/env bash\n' >"$old_repo/install.sh"
  : >"$old_repo/uninstall.sh"
  : >"$old_repo/lib/ledger.py"
  printf 'old\n' >"$old_link/report.md"
  ln -s "$old_link" "$TARGET/.claude/commands/token-saver"
  _run_install
  assert_eq "$REPO_ROOT/commands/token-saver" \
    "$(readlink "$TARGET/.claude/commands/token-saver")" "Claude legacy command link"
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/commands/token-saver" "Claude command .gitignore"
}

test_install_shだけの外来コマンドリンクは張り替えない() {
  _setup_target
  foreign="$TEST_TMP/foreign-cmd-repo"
  mkdir -p "$foreign/commands/token-saver" "$TARGET/.claude/commands"
  : >"$foreign/install.sh"
  printf 'foreign\n' >"$foreign/commands/token-saver/report.md"
  ln -s "$foreign/commands/token-saver" "$TARGET/.claude/commands/token-saver"
  _run_install
  assert_eq "$foreign/commands/token-saver" \
    "$(readlink "$TARGET/.claude/commands/token-saver")" "外来コマンドリンク"
  assert_contains "$(cat "$TARGET/.claude/commands/token-saver/report.md")" \
    "foreign" "外来コマンドの内容"
  assert_contains "$INSTALL_OUT" "警告" "出力"
}

test_personal後のsharedがコマンドをgitignoreへ書く() {
  _setup_target
  _run_install_args --personal
  assert_file_missing "$TARGET/.gitignore" "personal後の.gitignore"
  _run_install_args --shared
  assert_contains "$(cat "$TARGET/.gitignore")" \
    ".claude/commands/token-saver" "shared後のコマンド.gitignore"
}
