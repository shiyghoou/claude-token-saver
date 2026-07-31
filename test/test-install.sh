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

test_移行が起きたら適用一覧に載せる() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _run_install
  assert_contains "$INSTALL_OUT$INSTALL_ERR" "移行" "移行したことを伝える"
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
  led="$(cat "$TARGET/.token-saver/installed.json")"
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
