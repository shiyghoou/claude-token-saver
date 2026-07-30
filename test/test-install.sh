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

# パーミッションを 8 進で返す。GNU と BSD で書式が違う。
_perm() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
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
  # 実体が現れたら登録されることまで見る。条件付きスキップにすると、
  # 段階3でファイルが増えた瞬間にテストが丸ごと空振りして恒久的に緑になる。
  _load_hook_commands Stop
  if [ -f "$REPO_ROOT/scripts/suggest-session-cut.sh" ]; then
    assert_contains "$HOOK_COMMANDS" "suggest-session-cut.sh" "Stop のコマンド"
  else
    assert_not_contains "$HOOK_COMMANDS" "suggest-session-cut.sh" "Stop のコマンド"
    # 未実装であることは、取りこぼしの警告ではなく予定として伝える。
    assert_contains "$INSTALL_OUT" "段階3" "出力"
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

# --- 以下、敵対的レビューの指摘に対する回帰テスト -----------------------------

GITIGNORE_START="# claude-token-saver (install.sh が追記。uninstall.sh で削除される)"
GITIGNORE_END="# claude-token-saver end"

# クローンを別の場所へ複製する。CTS_HOME 側のパスを変えた検証に使う。
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

  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf '空白パスでも読める\n' >"$TARGET/.claude/.handoff/pending/a.md"

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
  before="$(_mtime "$TARGET/.gitignore")"
  _run_install
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
  local cmds
  cmds="$(_hook_commands SessionStart)"
  assert_contains "$cmds" "独自フック" "SessionStart のコマンド"
  assert_contains "$(cat "$SETTINGS")" "matcher" "settings.local.json"
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
  before="$(_mtime "$SETTINGS")"
  _run_install
  after="$(_mtime "$SETTINGS")"
  assert_eq "$before" "$after" "settings.local.json の mtime"
}

test_設置したものを台帳へ記録する() {
  _setup_target
  _run_install
  # 「何を設置したか」を記録していないと、uninstall が推測で判定するしかなくなる。
  local led
  led="$(cat "$TARGET/.claude/.token-saver/installed.json")"
  assert_contains "$led" "session-handoff" "台帳"
  assert_contains "$led" "handoff-check.sh" "台帳"
}

test_クローンに__pycache__を書き散らさない() {
  _setup_target
  local clone="$TEST_TMP/clone"
  _clone_repo "$clone"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  # 導入先から呼ばれる道具である。利用者のクローンに生成物を残さない。
  assert_file_missing "$clone/lib/__pycache__"
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
  rm -rf "$clone/scripts" "$clone/skills"
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
