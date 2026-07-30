#!/usr/bin/env bash
# uninstall.sh の検証。install.sh の取り消しであること、
# そして引き継ぎの実ファイルを決して消さないことが要点。

INSTALL="$REPO_ROOT/install.sh"
UNINSTALL="$REPO_ROOT/uninstall.sh"

_setup_target() {
  TARGET="$TEST_TMP/target"
  mkdir -p "$TARGET"
  ( cd "$TARGET" && git init -q . )
  SETTINGS="$TARGET/.claude/settings.local.json"
}

_run_install()   { bash "$INSTALL" "$TARGET" >/dev/null 2>&1; }

_run_uninstall() {
  bash "$UNINSTALL" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  UNINSTALL_STATUS=$?
  UNINSTALL_OUT="$(cat "$TEST_TMP/.out")"
  UNINSTALL_ERR="$(cat "$TEST_TMP/.err")"
}

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

test_フックの登録を外す() {
  _setup_target
  _run_install
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
  assert_not_contains "$(_hook_commands SessionStart)" "handoff-check.sh" "SessionStart のコマンド"
}

test_導入先の他のフックは残す() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo 残すべきフック" } ] }
    ]
  }
}
EOF
  _run_install
  _run_uninstall
  assert_contains "$(_hook_commands SessionStart)" "残すべきフック" "SessionStart のコマンド"
}

test_導入先の他の設定キーは残す() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  _run_uninstall
  assert_contains "$(cat "$SETTINGS")" "Bash(ls:*)" "settings.local.json"
}

test_引き継ぎの実ファイルは消さない() {
  _setup_target
  _run_install
  printf '消えてはいけない引き継ぎ\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf '消えてはいけない消費済み\n' >"$TARGET/.claude/.handoff/consumed/b.md"
  _run_uninstall
  assert_file_exists "$TARGET/.claude/.handoff/pending/a.md"
  assert_file_exists "$TARGET/.claude/.handoff/consumed/b.md"
}

test_引き継ぎが残っていれば警告する() {
  _setup_target
  _run_install
  printf '未消費\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT" ".claude/.handoff" "出力"
}

test_gitignore_の追記を削除する() {
  _setup_target
  _run_install
  _run_uninstall
  assert_not_contains "$(cat "$TARGET/.gitignore" 2>/dev/null || true)" \
    ".claude/.token-saver/" ".gitignore"
}

test_gitignore_の他の行は残す() {
  _setup_target
  printf 'node_modules/\ndist/\n' >"$TARGET/.gitignore"
  _run_install
  _run_uninstall
  local gi
  gi="$(cat "$TARGET/.gitignore")"
  assert_contains "$gi" "node_modules/" ".gitignore"
  assert_contains "$gi" "dist/" ".gitignore"
}

test_スキルのリンクを外す() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.claude/skills/session-handoff"
}

test_コピーで配置したスキルも外す() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  _run_uninstall
  assert_file_missing "$TARGET/.claude/skills/session-handoff"
}

test_導入先が自前で置いたスキルは消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/my-own-skill"
  printf 'mine\n' >"$TARGET/.claude/skills/my-own-skill/SKILL.md"
  _run_install
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/my-own-skill/SKILL.md"
}

test_導入先が自前で置いた同名スキルは消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/session-handoff"
  printf '導入先が自分で書いたもの\n' >"$TARGET/.claude/skills/session-handoff/SKILL.md"
  _run_install
  _run_uninstall
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "導入先が自分で書いたもの" "既存スキルの内容"
}

test_未導入の状態で実行しても終了コード0() {
  _setup_target
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
}

test_二度実行しても終了コード0() {
  _setup_target
  _run_install
  _run_uninstall
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "2回目の終了コード"
}

test_壊れた_settings_は上書きせず失敗する() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"hooks": \n' >"$SETTINGS"
  _run_uninstall
  assert_ne "0" "$UNINSTALL_STATUS" "終了コード"
  assert_contains "$(cat "$SETTINGS")" '{"hooks":' "settings.local.json（原状のまま）"
}

test_残った_settings_は妥当な_JSON_である() {
  _setup_target
  _run_install
  _run_uninstall
  # 中身が空なら uninstall が消すので、残っている場合だけ検査する。
  [ -f "$SETTINGS" ] || return 0
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SETTINGS" ||
    _fail "settings.local.json が妥当な JSON でない"
}

# --- 以下、敵対的レビューの指摘に対する回帰テスト -----------------------------

GITIGNORE_START="# claude-token-saver (install.sh が追記。uninstall.sh で削除される)"
GITIGNORE_END="# claude-token-saver end"

_clone_repo() {
  local dest="$1"
  mkdir -p "$dest"
  cp -R "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$dest/"
  local d
  for d in scripts skills lib; do
    [ -d "$REPO_ROOT/$d" ] && cp -R "$REPO_ROOT/$d" "$dest/"
  done
  return 0
}

test_END_マーカーが無ければ_gitignore_を削らない() {
  _setup_target
  printf 'dist/\n.env\n%s\n.claude/.handoff/\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  local before
  before="$(cat "$TARGET/.gitignore")"
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
  assert_eq "$before" "$(cat "$TARGET/.gitignore")" ".gitignore"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "警告" "出力"
}

test_同じ接頭辞のユーザーのコメント行を誤認しない() {
  _setup_target
  printf '# claude-token-saver は便利\ndist/\n.env\n' >"$TARGET/.gitignore"
  _run_install
  _run_uninstall
  local gi
  gi="$(cat "$TARGET/.gitignore")"
  assert_contains "$gi" "# claude-token-saver は便利" ".gitignore"
  assert_contains "$gi" "dist/" ".gitignore"
  assert_contains "$gi" ".env" ".gitignore"
}

test_ブロックと無関係な末尾の空行は消さない() {
  _setup_target
  {
    printf 'node_modules/\n\n'
    printf '%s\n' "$GITIGNORE_START"
    printf '.claude/.handoff/\n'
    printf '%s\n' "$GITIGNORE_END"
    printf 'dist/\n\n\n'
  } >"$TARGET/.gitignore"
  _run_uninstall
  # コマンド置換は末尾の改行を落とすため、repr で厳密に比べる。
  local actual
  actual="$(python3 -c 'import sys; print(repr(open(sys.argv[1]).read()))' "$TARGET/.gitignore")"
  assert_eq "'node_modules/\ndist/\n\n\n'" "$actual" ".gitignore"
}

test_空白を含むパスで登録したフックも外せる() {
  _setup_target
  local clone="$TEST_TMP/my clone"
  _clone_repo "$clone"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  # 導入したのとは別のクローンから外せねばならない。
  _run_uninstall
  assert_not_contains "$(_hook_commands SessionStart 2>/dev/null || true)" \
    "handoff-check.sh" "SessionStart のコマンド"
}

test_非クォートで登録された古いフックも外せる() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$REPO_ROOT/scripts/handoff-check.sh" } ] }
    ]
  }
}
EOF
  _run_uninstall
  assert_not_contains "$(cat "$SETTINGS" 2>/dev/null || true)" \
    "handoff-check.sh" "settings.local.json"
}

test_別のクローンで設置したスキルのリンクも外す() {
  _setup_target
  _run_install
  # 導入時にはあったが、この uninstall を実行するクローンには無いスキルを模す。
  mkdir -p "$TEST_TMP/other-clone/skills/extra-skill"
  printf 'x\n' >"$TEST_TMP/other-clone/skills/extra-skill/SKILL.md"
  ln -s "$TEST_TMP/other-clone/skills/extra-skill" "$TARGET/.claude/skills/extra-skill"
  _run_uninstall
  assert_file_missing "$TARGET/.claude/skills/extra-skill"
}

test_導入先が自前で置いた実ディレクトリのスキルは残す() {
  _setup_target
  _run_install
  mkdir -p "$TARGET/.claude/skills/my-own-skill"
  printf 'mine\n' >"$TARGET/.claude/skills/my-own-skill/SKILL.md"
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/my-own-skill/SKILL.md"
}

test_空になったディレクトリとファイルを残さない() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.claude/.handoff/pending"
  assert_file_missing "$TARGET/.claude/.handoff/consumed"
  assert_file_missing "$TARGET/.claude/.handoff"
  assert_file_missing "$TARGET/.claude/.token-saver"
  assert_file_missing "$TARGET/.gitignore"
  assert_file_missing "$SETTINGS"
}

test_実ファイルのある_handoff_は残す() {
  _setup_target
  _run_install
  printf '残す\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _run_uninstall
  assert_file_exists "$TARGET/.claude/.handoff/pending/a.md"
}

test_install_前から在った_gitignore_は消さない() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  _run_install
  _run_uninstall
  assert_file_exists "$TARGET/.gitignore"
  assert_contains "$(cat "$TARGET/.gitignore")" "node_modules/" ".gitignore"
}
