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

# settings.local.json から指定フックのコマンド一覧を取り出す。
_hook_commands() {
  local event="$1"
  python3 -c '
import json, sys
event = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
for group in data.get("hooks", {}).get(event, []):
    for h in group.get("hooks", []):
        print(h.get("command", ""))
' "$event" "$SETTINGS"
}

test_settings_が無ければ作って_SessionStart_に登録する() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$SETTINGS"
  assert_contains "$(_hook_commands SessionStart)" "handoff-check.sh" "SessionStart のコマンド"
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
  assert_eq "0" "$INSTALL_STATUS" "2回目の終了コード"
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "handoff-check.sh の登録数"
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
  assert_contains "$gi" ".claude/.handoff/" ".gitignore"
  assert_contains "$gi" ".claude/.token-saver/" ".gitignore"
}

test_gitignore_への追記は二度実行しても重複しない() {
  _setup_target
  _run_install
  _run_install
  assert_count 1 "$(cat "$TARGET/.gitignore")" ".claude/.handoff/" ".gitignore の追記"
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
  assert_file_exists "$TARGET/.claude/.handoff/pending"
  assert_file_exists "$TARGET/.claude/.handoff/consumed"
}

test_非_git_ディレクトリでも失敗しない() {
  _setup_target
  rm -rf "$TARGET/.git"
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$SETTINGS"
}

test_存在しないフックスクリプトは登録しない() {
  _setup_target
  _run_install
  # 段階3で追加される Stop フックは、実体が無いうちは登録してはならない。
  # 実体の無いコマンドを登録すると、導入先のセッションでフックが毎回失敗する。
  if [ ! -f "$REPO_ROOT/scripts/suggest-session-cut.sh" ]; then
    assert_not_contains "$(_hook_commands Stop 2>/dev/null || true)" "suggest-session-cut.sh" "Stop のコマンド"
  fi
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
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf '実行できる引き継ぎ\n' >"$TARGET/.claude/.handoff/pending/a.md"

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
