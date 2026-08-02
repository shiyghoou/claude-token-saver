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

_run_uninstall_args() {
  bash "$UNINSTALL" "$@" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  UNINSTALL_STATUS=$?
  UNINSTALL_OUT="$(cat "$TEST_TMP/.out")"
  UNINSTALL_ERR="$(cat "$TEST_TMP/.err")"
}

# 台帳の無い旧環境向けの推測経路。既定では通らないので、明示的に opt-in する。
_run_uninstall_guess() {
  bash "$UNINSTALL" --guess "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  UNINSTALL_STATUS=$?
  UNINSTALL_OUT="$(cat "$TEST_TMP/.out")"
  UNINSTALL_ERR="$(cat "$TEST_TMP/.err")"
}

# 台帳を任意の内容へ差し替える。空・壊れた JSON・スキーマ違いを作るのに使う。
_write_ledger() {
  mkdir -p "$TARGET/.token-saver"
  printf '%s' "$1" >"$TARGET/.token-saver/installed.json"
}

# 指定フックのコマンド一覧を HOOK_COMMANDS へ読み込む。
# uninstall 後は settings.local.json 自体が消えることがある。素の python に
# 読ませると FileNotFoundError で標準出力が空になり、不在アサーションが
# 無条件に成立してしまう。「消えた」と「読めなかった」を区別する。
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

# 不在を明示的な文言として返す。`cat 2>/dev/null || true` は空文字列を返すため、
# 不在アサーションが常に成立してしまう。
_gitignore_text() {
  if [ ! -f "$TARGET/.gitignore" ]; then
    printf '(.gitignore は存在しない)\n'
    return 0
  fi
  cat "$TARGET/.gitignore"
}

_settings_text() {
  if [ ! -f "$SETTINGS" ]; then
    printf '(settings.local.json は存在しない)\n'
    return 0
  fi
  cat "$SETTINGS"
}

test_フックの登録を外す() {
  _setup_target
  _run_install
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "SessionStart のコマンド"
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
  printf '消えてはいけない引き継ぎ\n' >"$TARGET/.token-saver/handoff/pending/a.md"
  printf '消えてはいけない消費済み\n' >"$TARGET/.token-saver/handoff/consumed/b.md"
  _run_uninstall
  assert_file_exists "$TARGET/.token-saver/handoff/pending/a.md"
  assert_file_exists "$TARGET/.token-saver/handoff/consumed/b.md"
}

test_引き継ぎが残っていれば警告する() {
  _setup_target
  _run_install
  printf '未消費\n' >"$TARGET/.token-saver/handoff/pending/a.md"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT" ".token-saver/handoff" "出力"
}

test_gitignore_の追記を削除する() {
  _setup_target
  _run_install
  _run_uninstall
  assert_not_contains "$(_gitignore_text)" ".token-saver/" ".gitignore"
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
  assert_file_exists "$SETTINGS" "install後のsettings.local.json"
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
  assert_not_contains "$gi" "$GITIGNORE_START" "管理ブロックのSTART"
  assert_not_contains "$gi" "$GITIGNORE_END" "管理ブロックのEND"
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
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "SessionStart のコマンド"
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
  # 台帳の無い旧環境である。既定では推測へ落ちないので --guess を明示する。
  _run_uninstall_guess
  assert_not_contains "$(_settings_text)" "handoff-check.sh" "settings.local.json"
}

test_別のクローンで設置したスキルのリンクも外す() {
  _setup_target
  # 導入時にはあったが、この uninstall を実行するクローンには無いスキルを模す。
  local clone="$TEST_TMP/other-clone"
  _clone_repo "$clone"
  mkdir -p "$clone/skills/extra-skill"
  printf 'x\n' >"$clone/skills/extra-skill/SKILL.md"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  assert_file_exists "$TARGET/.claude/skills/extra-skill"
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
  assert_file_missing "$TARGET/.token-saver/handoff/pending"
  assert_file_missing "$TARGET/.token-saver/handoff/consumed"
  assert_file_missing "$TARGET/.token-saver/handoff"
  assert_file_missing "$TARGET/.token-saver"
  assert_file_missing "$TARGET/.gitignore"
  assert_file_missing "$SETTINGS"
}

test_実ファイルのある_handoff_は残す() {
  _setup_target
  _run_install
  printf '残す\n' >"$TARGET/.token-saver/handoff/pending/a.md"
  _run_uninstall
  assert_file_exists "$TARGET/.token-saver/handoff/pending/a.md"
}

test_新パスの空ディレクトリを片付ける() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.token-saver/handoff/pending" "pending"
  assert_file_missing "$TARGET/.token-saver/handoff" "handoff"
  assert_file_missing "$TARGET/.token-saver" ".token-saver"
}

test_引き継ぎの実ファイルは残す() {
  _setup_target
  _run_install
  printf 'A\n' >"$TARGET/.token-saver/handoff/consumed/a.md"
  _run_uninstall
  assert_file_exists "$TARGET/.token-saver/handoff/consumed/a.md" "引き継ぎ"
}

test_引き継ぎを残したことを新パスで案内する() {
  _setup_target
  _run_install
  printf 'A\n' >"$TARGET/.token-saver/handoff/consumed/a.md"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT" ".token-saver/handoff" "案内文のパス"
  assert_not_contains "$UNINSTALL_OUT" ".claude/.handoff" "旧パスを案内しない"
}

test_新パスの台帳を消す() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.token-saver/installed.json" "台帳"
}

test_導入と無関係な同名スキルのリンクは外さない() {
  _setup_target
  _run_install
  # 導入先が自分で張った、社内共有のスキルへのリンク。リンク先の basename と
  # 親ディレクトリ名だけで判定すると、これも「自分のもの」と誤認して消す。
  mkdir -p "$TEST_TMP/shared/skills/mine"
  printf '利用者のスキル\n' >"$TEST_TMP/shared/skills/mine/SKILL.md"
  ln -s "$TEST_TMP/shared/skills/mine" "$TARGET/.claude/skills/mine"
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/mine"
  assert_contains "$(cat "$TARGET/.claude/skills/mine/SKILL.md")" "利用者のスキル" "スキルの内容"
}

test_空白入りパスの非クォート登録も外せる() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  # クォートせずに登録していた頃の残骸。単純な先頭トークンの basename では
  # "with" になり同定できず、外れないまま「1 件外した」と報告される。
  cat >"$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$TEST_TMP/my clone/scripts/handoff-check.sh" } ] }
    ]
  }
}
EOF
  # 台帳の無い旧環境である。既定では推測へ落ちないので --guess を明示する。
  _run_uninstall_guess
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "SessionStart のコマンド"
}

test_Windows_風のパスで登録されたフックも外せる() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "C:\\Users\\me\\cts\\scripts\\handoff-check.sh" } ] }
    ]
  }
}
EOF
  # 台帳の無い旧環境である。既定では推測へ落ちないので --guess を明示する。
  _run_uninstall_guess
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "SessionStart のコマンド"
}

test_インタプリタ経由で登録されたフックも外せる() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash /opt/cts/scripts/handoff-check.sh" } ] }
    ]
  }
}
EOF
  # 台帳の無い旧環境である。既定では推測へ落ちないので --guess を明示する。
  _run_uninstall_guess
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "SessionStart のコマンド"
}

test_台帳無しのインストールは旧フックを消さず警告する() {
  _setup_target
  local clone="$TEST_TMP/my clone"
  _clone_repo "$clone"
  mkdir -p "$TARGET/.claude"
  # 旧版が非クォートで登録した状態から、新版で install し直す場面。
  cat >"$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$clone/scripts/handoff-check.sh" } ] }
    ]
  }
}
EOF
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  _load_hook_commands SessionStart
  # 波1では台帳無し install の推測削除を禁止する。旧フックは残るが、利用者の
  # フックを巻き込まないことを優先し、警告を出して判断を委ねる。
  assert_count 2 "$HOOK_COMMANDS" "handoff-check.sh" "handoff-check.sh の登録数"
}

test_未導入のリポジトリの_settings_を再整形しない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  cat >"$SETTINGS" <<'EOF'
{
    "permissions": {"allow": ["Bash(ls:*)"]}
}
EOF
  local before
  before="$(cat "$SETTINGS")"
  _run_uninstall
  # 一度も導入していない利用者のファイルを、取り外しのついでに書き換えない。
  assert_eq "$before" "$(cat "$SETTINGS")" "settings.local.json"
}

test_gitignore_のブロックが2つあれば両方削除する() {
  _setup_target
  {
    printf '%s\n.claude/.handoff/\n%s\n' "$GITIGNORE_START" "$GITIGNORE_END"
    printf 'dist/\n'
    printf '%s\n.claude/.handoff/\n%s\n' "$GITIGNORE_START" "$GITIGNORE_END"
  } >"$TARGET/.gitignore"
  _run_uninstall
  local gi
  gi="$(_gitignore_text)"
  assert_not_contains "$gi" "$GITIGNORE_START" ".gitignore"
  assert_not_contains "$gi" "$GITIGNORE_END" ".gitignore"
  assert_contains "$gi" "dist/" ".gitignore"
}

test_末尾の空行は往復で保たれる() {
  _setup_target
  printf 'a\nb\n\n\n\n' >"$TARGET/.gitignore"
  _run_install
  _run_uninstall
  local actual
  actual="$(python3 -c 'import sys; print(repr(open(sys.argv[1]).read()))' "$TARGET/.gitignore")"
  assert_eq "'a\nb\n\n\n\n'" "$actual" ".gitignore"
}

test_内容が同じ控えは片付ける() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  _run_uninstall
  # 原状へ戻ったのに控えだけ残ると、個人設定のコピーが放置される。
  assert_file_missing "$SETTINGS.cts-backup"
}

test_控えと差があれば残して知らせる() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"permissions":{"allow":["Bash(ls:*)"]}}\n' >"$SETTINGS"
  _run_install
  python3 -c '
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
d["env"] = {"FOO": "bar"}
with open(p, "w") as f:
    json.dump(d, f)
' "$SETTINGS"
  _run_uninstall
  assert_file_exists "$SETTINGS.cts-backup"
  assert_contains "$UNINSTALL_OUT" "cts-backup" "出力"
}

test_gitignore_が壊れていれば完了と言わず警告をまとめる() {
  _setup_target
  printf 'dist/\n%s\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "警告" "出力"
  # 何も外せていないのに「完了。」で終わると、取り残しに気づけない。
  assert_not_contains "$UNINSTALL_OUT" "完了。" "出力"
}

test_CTS_STRICT_なら警告で非ゼロを返す() {
  _setup_target
  printf 'dist/\n%s\n' "$GITIGNORE_START" >"$TARGET/.gitignore"
  local rc=0
  CTS_STRICT=1 bash "$UNINSTALL" "$TARGET" >/dev/null 2>&1 || rc=$?
  assert_ne "0" "$rc" "終了コード"
}

test_追跡済みの空の_gitignore_は消さない() {
  _setup_target
  : >"$TARGET/.gitignore"
  ( cd "$TARGET" &&
    git add .gitignore &&
    git -c user.email=t@example.com -c user.name=t commit -qm '空の gitignore' ) >/dev/null 2>&1
  _run_install
  _run_uninstall
  # install.sh が作ったのでなければ、空になっても消してはならない。
  assert_file_exists "$TARGET/.gitignore"
}

test_台帳を残さない() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.token-saver/installed.json"
}

test_install_前から在った_gitignore_は消さない() {
  _setup_target
  printf 'node_modules/\n' >"$TARGET/.gitignore"
  _run_install
  _run_uninstall
  assert_file_exists "$TARGET/.gitignore"
  assert_contains "$(cat "$TARGET/.gitignore")" "node_modules/" ".gitignore"
}

# --- 台帳の記録が無い・壊れているときの fail-closed ---------------------------
# 「台帳ファイルが在る」を「記録が在る」と取り違えると、記録ゼロの台帳で
# 推測経路へ落ち、利用者のフックを消して settings.local.json ごと削除する。

# 台帳の壊れ方。どれか1つでも「記録が在る」と数えると事故になる。
_LEDGER_EMPTY_VARIANTS=('{}' 'null' '[]' '"x"' '' '{"skills":"リストでない"}' 'not json')

test_記録の無い台帳では推測に落ちず利用者のフックを残す() {
  local variant
  for variant in "${_LEDGER_EMPTY_VARIANTS[@]}"; do
    rm -rf "$TEST_TMP/target"
    _setup_target
    # 利用者が自分で書いた、名前がぶつかるだけのフック。推測はファイル名で
    # 判定するため、これを自分のものと誤認して削除する。「echo 何か」のような
    # 当たらないコマンドでは、推測経路を通しても消えないので検出できない。
    # install.sh を通さずに状態を作る。install.sh は自分の登録を必ず入れ直す
    # ため推測で掃除してよい側であり、その掃除がこの検証を先に壊してしまう。
    mkdir -p "$TARGET/.claude" "$TEST_TMP/user-own/scripts"
    : >"$TEST_TMP/user-own/scripts/handoff-check.sh"
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
      "$TEST_TMP/user-own/scripts/handoff-check.sh" >"$SETTINGS"
    _write_ledger "$variant"
    _run_uninstall
    assert_eq "0" "$UNINSTALL_STATUS" "台帳=[$variant] の終了コード"
    assert_file_exists "$SETTINGS"
    assert_contains "$(_hook_commands SessionStart)" "user-own" "台帳=[$variant] の SessionStart"
    # 「何もしなかった」ことを名指しで伝えること。他の警告で件数を満たしていても、
    # フックの取り残しを黙っていては利用者が気づけない。
    assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "台帳にフックの記録が無い" \
      "台帳=[$variant] の出力"
    assert_not_contains "$UNINSTALL_OUT" "完了。" "台帳=[$variant] の出力"
  done
}

test_記録の無い台帳ではスキルのリンクと_gitignore_の除外を残す() {
  local variant
  for variant in "${_LEDGER_EMPTY_VARIANTS[@]}"; do
    rm -rf "$TEST_TMP/target"
    _setup_target
    _run_install
    _write_ledger "$variant"
    _run_uninstall
    # リンクを残すなら除外も残さねばならない。除外だけ外すと、絶対パスを指す
    # リンクが未追跡ファイルとして git に現れ、利用者の作業を汚す。
    assert_file_exists "$TARGET/.claude/skills/session-handoff"
    assert_contains "$(_gitignore_text)" ".claude/skills/session-handoff" "台帳=[$variant] の .gitignore"
  done
}

test_記録の無い台帳では_CTS_STRICT_で非ゼロを返す() {
  _setup_target
  _run_install
  _write_ledger '{}'
  local rc=0
  CTS_STRICT=1 bash "$UNINSTALL" "$TARGET" >/dev/null 2>&1 || rc=$?
  # 外し切れていないのに rc=0 を返すと、CI から呼んだ側が取り残しに気づけない。
  assert_ne "0" "$rc" "終了コード"
}

test_未導入なら利用者の設定ファイルを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{}\n' >"$SETTINGS"
  _run_uninstall
  # 1件も外していないのに利用者のファイルへ手を出してはならない。
  assert_file_exists "$SETTINGS"
}

test_未導入なら利用者の空の_claude_ディレクトリを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  _run_uninstall
  assert_file_exists "$TARGET/.claude"
}

# --- 推測経路（--guess）------------------------------------------------------

test_推測経路は_guess_を付けたときだけ通る() {
  _setup_target
  # 利用者が社内共有リポジトリの skills/ へ張ったリンク。install.sh という
  # ありふれた名前が親に在るだけで「自分のもの」と誤認される形をしている。
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/skills/session-handoff"
  printf '利用者の共有スキル\n' >"$shared/skills/session-handoff/SKILL.md"
  : >"$shared/install.sh"
  mkdir -p "$TARGET/.claude/skills"
  ln -s "$shared/skills/session-handoff" "$TARGET/.claude/skills/session-handoff"

  # 利用者が自分で書いた、名前がぶつかるだけのフック。推測はファイル名で
  # 判定するため、これを自分のものと誤認して削除する。
  mkdir -p "$TARGET/.claude" "$TEST_TMP/user-own/scripts"
  : >"$TEST_TMP/user-own/scripts/handoff-check.sh"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "$TEST_TMP/user-own/scripts/handoff-check.sh" >"$SETTINGS"

  # 台帳を作らない（_run_install を呼ばない）。既定では触ってはならない。
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/session-handoff"
  assert_contains "$(_hook_commands SessionStart)" "user-own" "SessionStart のコマンド"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "--guess" "出力"

  # --guess を明示したときだけ従来の推測へ落ちる。
  # 推測は利用者の設置物を巻き込む。それが opt-in である理由そのものである。
  _run_uninstall_guess
  assert_file_missing "$TARGET/.claude/skills/session-handoff"
  assert_not_contains "$(_settings_text)" "user-own" "settings.local.json"
}

test_二度目の取り外しでも推測に落ちない() {
  _setup_target
  _run_install
  _run_uninstall
  # 1回目で台帳が消えるため、2回目が必ず推測経路になっていた。
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/skills/session-handoff"
  printf '利用者の共有スキル\n' >"$shared/skills/session-handoff/SKILL.md"
  : >"$shared/install.sh"
  mkdir -p "$TARGET/.claude/skills"
  ln -s "$shared/skills/session-handoff" "$TARGET/.claude/skills/session-handoff"
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/session-handoff"
}

# --- 台帳の name をパスへ連結する経路 ----------------------------------------

# 台帳の skills を任意の内容へ差し替える。
_replace_ledger_skills() {
  python3 - "$TARGET/.token-saver/installed.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, name, src, mode = sys.argv[1:5]
with open(path) as f:
    data = json.load(f)
data["skills"] = [{"name": name, "src": src, "mode": mode}]
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False)
PY
}

test_台帳の名前に相対パスがあっても導入先の外を消さない() {
  _setup_target
  _run_install
  local outside="$TEST_TMP/outside"
  mkdir -p "$outside/real"
  ln -s "$outside/real" "$outside/important-link"
  # .claude/skills/../../../outside/important-link は $TEST_TMP/outside/… を指す。
  _replace_ledger_skills "../../../outside/important-link" "$outside/real" link
  _run_uninstall
  assert_file_exists "$outside/important-link"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "不正" "出力"
}

test_台帳の名前にタブがあっても別のスキルを消さない() {
  _setup_target
  _run_install
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/victim"
  printf '利用者のスキル\n' >"$shared/victim/SKILL.md"
  ln -s "$shared/victim" "$TARGET/.claude/skills/victim"
  # 行プロトコル（TSV）は tab を表現できない。素朴に読むと name=victim になり、
  # 記録していないリンクを対象にしてしまう。
  _replace_ledger_skills "$(printf 'victim\t%s' "$shared/victim")" "$shared/victim" link
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/victim"
  assert_contains "$(cat "$TARGET/.claude/skills/victim/SKILL.md")" "利用者のスキル" "スキルの内容"
}

test_記録にリンク先が無ければ触らない() {
  _setup_target
  _run_install
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/session-handoff"
  printf '利用者のスキル\n' >"$shared/session-handoff/SKILL.md"
  # rm -f はディレクトリを消せず黙って失敗する。CTS_NO_SYMLINK やシンボリック
  # リンクが使えない環境では _run_install がスキルをディレクトリのコピーとして
  # 設置するため、rm -f では dest が残ったままになり、次の ln -s がその
  # ディレクトリの中にリンクを作ってしまう（本体の外とはいえテストの隔離が
  # 破れる経路そのものである）。rm -rf でリンク・ディレクトリのどちらでも
  # 確実に片付けてから張り直す。
  rm -rf "$TARGET/.claude/skills/session-handoff"
  ln -s "$shared/session-handoff" "$TARGET/.claude/skills/session-handoff"
  # src が空の記録は「何を指していたか分からない」であり、削除の許可ではない。
  _replace_ledger_skills session-handoff "" link
  _run_uninstall
  assert_file_exists "$TARGET/.claude/skills/session-handoff"
  assert_contains "$(cat "$TARGET/.claude/skills/session-handoff/SKILL.md")" \
    "利用者のスキル" "スキルの内容"
}

# --- 台帳の寿命と後片付け ----------------------------------------------------

test_取り残しがあれば台帳を残す() {
  _setup_target
  _run_install
  # 導入後に導入先がリンクを差し替えた状態。外せないので取り残しになる。
  local shared="$TEST_TMP/shared"
  mkdir -p "$shared/session-handoff"
  # rm -f はディレクトリを消せず黙って失敗する（詳細は同種のコメントを
  # 参照）。rm -rf で確実に片付けてから張り直す。
  rm -rf "$TARGET/.claude/skills/session-handoff"
  ln -s "$shared/session-handoff" "$TARGET/.claude/skills/session-handoff"
  _run_uninstall
  # 台帳を消すと、次回は記録の無い状態＝何もできない状態になる。
  assert_file_exists "$TARGET/.token-saver/installed.json"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "警告" "出力"
}

test_導入後にコミットされた_gitignore_は消さない() {
  _setup_target
  _run_install
  ( cd "$TARGET" &&
    git add .gitignore &&
    git -c user.email=t@example.com -c user.name=t commit -qm 'gitignore を追加' ) >/dev/null 2>&1
  _run_uninstall
  # install.sh が作ったものでも、利用者がコミットした後なら消してはならない。
  assert_file_exists "$TARGET/.gitignore"
}

test_同じグループに同居する利用者のフックを巻き込まない() {
  _setup_target
  _run_install
  # install.sh が作ったグループへ、利用者が自分のフックを足した状態。
  # グループ単位で落とす実装だと、これを巻き込んで消す。
  python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
group = data["hooks"]["SessionStart"][0]
group["hooks"].append({"type": "command", "command": "echo 同居する利用者のフック"})
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
  _run_uninstall
  local cmds
  cmds="$(_hook_commands SessionStart)"
  assert_contains "$cmds" "同居する利用者のフック" "SessionStart のコマンド"
  assert_not_contains "$cmds" "handoff-check.sh" "SessionStart のコマンド"
}

test_START_が2つあれば利用者の行を飲み込まず警告する() {
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
  _run_uninstall
  # START 1つ+END 2つは警告するのに、START 2つ+END 1つを黙って消すのは非対称。
  assert_eq "$before" "$(cat "$TARGET/.gitignore")" ".gitignore"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "警告" "出力"
}

# --- 旧パスの台帳へのフォールバック -------------------------------------------
# 旧版で install したあと新版の uninstall.sh を使うと、台帳は .claude/.token-saver/
# 配下にあり新パスには無い。フォールバックが無いと fail-closed で
# 利用者のフックを残したまま外せなくなる。

test_旧パスの台帳を読んで外す() {
  _setup_target
  _run_install
  # 旧版の状態を作る: 台帳を旧パスへ戻す。
  mkdir -p "$TARGET/.claude/.token-saver"
  mv "$TARGET/.token-saver/installed.json" \
     "$TARGET/.claude/.token-saver/installed.json"
  _run_uninstall
  # フックが外れていること。推測に落ちていないこと。
  _load_hook_commands SessionStart
  assert_not_contains "$HOOK_COMMANDS" "handoff-check.sh" "フックが外れている"
  assert_file_missing "$TARGET/.claude/skills/session-handoff" "スキルのリンク"
}

# 旧台帳は移行元であり、外し切れた（警告ゼロの）ケースでは `rm -f` で必ず
# 消える。「読むだけで、無いことがある」を assert_file_missing だけで確かめると、
# else 分岐が毎回ここを通り then 分岐が到達不能になる（旧台帳が消えなかった
# ケースを一度も踏まない）タウトロジーになる。then 分岐がそもそも死んでいた
# 理由は、このテストのセットアップ（クリーンな uninstall）では warnings が
# 常に空になり、常に rm -f されるからである。
#
# 消えて良い理由は「移行元を残すと install.sh の移行が次回また同じ台帳を
# 拾ってしまう」ためであり、消してよいことと「読んでいる最中に書き換えない」
# ことは別の主張である。後者を確かめるため、読み取りが終わるまで書き込みが
# 起きないことを、旧台帳を読み取り専用（444）にして検証する。
# フォールバックの実装が「読んでから書き戻す」形に変わると、権限のある
# ディレクトリ内でも読み取り専用ファイルへの書き込みは open が拒否するため、
# python3 側が例外を投げて uninstall.sh は非 0 で終了する。`rm -f` は
# ファイル自体の権限ではなく親ディレクトリの書き込み権限を見るため、
# 444 のままでも削除自体は成功する。これにより「削除はする・書き込みはしない」
# という2つの性質を1本のテストで区別できる。
test_旧台帳は読まれたのち消費される() {
  _setup_target
  _run_install
  mkdir -p "$TARGET/.claude/.token-saver"
  mv "$TARGET/.token-saver/installed.json" \
     "$TARGET/.claude/.token-saver/installed.json"
  # rootで実行すると所有者権限により444でも書き込みが成功し得る。
  # このテストの読み取り専用検証は、通常ユーザーの権限で実行した結果を前提とする。
  chmod 444 "$TARGET/.claude/.token-saver/installed.json"
  _run_uninstall
  chmod 755 "$TARGET/.claude/.token-saver" 2>/dev/null || true
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード（読み取り専用でも書き込みは発生しないので成功する）"
  assert_file_missing "$TARGET/.claude/.token-saver/installed.json" "旧台帳は消費されて消える"
  assert_file_missing "$TARGET/.claude/.token-saver" "旧パスの器も片付く"
}

# 新パスの台帳を rm -f で完全に消す点が既存の記録無し検証と異なる。
# _write_ledger の変種はファイルを空・壊れた内容で「上書き」するだけで
# ファイル自体は在る。load() はその場合 json.loads('' or "{}") が例外を
# 投げずに成立するため、ファイルが本当に無い（open が OSError を投げる）
# 経路を一度も通らない。このテストは、新パスに続いて旧パスも本当に
# 存在しない場合の has-record 呼び出し（今回追加したフォールバック判定）を
# 実際に踏む。既存の test_記録の無い台帳では推測に落ちず利用者のフックを残す
# とは踏むコードパスが異なるため、重複ではない。
test_新旧どちらにも台帳が無ければ推測に落ちない() {
  _setup_target
  _run_install
  rm -f "$TARGET/.token-saver/installed.json"
  _run_uninstall
  # fail-closed。利用者のフックを勝手に消さない。
  _load_hook_commands SessionStart
  assert_contains "$HOOK_COMMANDS" "handoff-check.sh" "台帳が無ければフックを残す"
}

test_導入前から追跡済みの空_settingsは消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{}\n' >"$SETTINGS"
  ( cd "$TARGET" &&
    git add .claude/settings.local.json &&
    git -c user.email=t@example.com -c user.name=t commit -qm 'settings を追跡' ) >/dev/null 2>&1
  _run_install
  _run_uninstall
  assert_file_exists "$SETTINGS"
}

test_初回に生成した_settingsは再実行後のuninstallで消す() {
  _setup_target
  _run_install
  _run_install
  _run_uninstall
  assert_file_missing "$SETTINGS" "初回に生成した settings.local.json"
  assert_file_missing "$SETTINGS.cts-backup" "生成設定の控え"
}

test_既知フックを外せなければ台帳を残す() {
  _setup_target
  _run_install
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo 利用者のフック"}]}]}}\n' \
    >"$SETTINGS"
  _run_uninstall
  assert_file_exists "$TARGET/.token-saver/installed.json" "取り残しを記録する台帳"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "警告" "フックを外せない場合の警告"
}

test_旧パスだけに残った引き継ぎを案内する() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/consumed" "$TARGET/.claude/.token-saver"
  printf '旧パスの記録\n' >"$TARGET/.claude/.handoff/consumed/a.md"
  printf '{"skills":[],"hooks":[]}\n' >"$TARGET/.claude/.token-saver/installed.json"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" ".claude/.handoff" "旧パスの引き継ぎ案内"
}

test_引き継ぎのシンボリックリンクも案内する() {
  _setup_target
  mkdir -p "$TARGET/.token-saver/handoff/consumed" "$TARGET/.token-saver"
  printf 'リンク先の記録\n' >"$TEST_TMP/note.md"
  ln -s "$TEST_TMP/note.md" "$TARGET/.token-saver/handoff/consumed/note.md"
  printf '{"skills":[],"hooks":[]}\n' >"$TARGET/.token-saver/installed.json"
  _run_uninstall
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" ".token-saver/handoff" "引き継ぎリンクの案内"
}

test_guessでもスクリプト名だけを含む利用者コマンドを消さない() {
  _setup_target
  mkdir -p "$TARGET/.claude"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo handoff-check.sh"}]}]}}\n' \
    >"$SETTINGS"
  _run_uninstall_guess
  assert_contains "$(_hook_commands SessionStart)" "echo handoff-check.sh" "利用者コマンド"
}

test_導入先の余分な位置引数を拒否する() {
  _setup_target
  local out rc=0
  out="$(bash "$UNINSTALL" "$TARGET" "$TEST_TMP/other-target" 2>&1)" || rc=$?
  assert_ne "0" "$rc" "余分な位置引数の終了コード"
  assert_contains "$out" "1つ" "余分な位置引数の出力"
}

test_アンインストールのshared_guess組合せを変更前に拒否する() {
  _setup_target
  printf '利用者の除外\n' >"$TARGET/.gitignore"
  cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
  _run_uninstall_args --shared --guess
  assert_ne "0" "$UNINSTALL_STATUS" "終了コード"
  cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
    _fail "不正なスコープ指定で.gitignoreが変更された"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "スコープ" "エラー"
}

test_token_reportの導入先entrypointを安全かつ冪等に外す() {
  _setup_target
  _run_install
  entrypoint="$TARGET/.token-saver/token-report.sh"
  assert_file_exists "$entrypoint" "導入先entrypoint"
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "1回目のuninstall終了コード"
  assert_file_missing "$entrypoint" "取り外したentrypoint"
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "2回目のuninstall終了コード"
  assert_file_missing "$entrypoint" "2回目も不在のentrypoint"
}

test_差し替えられたtoken_report_entrypointは消さない() {
  _setup_target
  _run_install
  entrypoint="$TARGET/.token-saver/token-report.sh"
  printf '#!/usr/bin/env bash\nprintf "利用者のentrypoint\\n"\n' >"$entrypoint"
  _run_uninstall
  assert_file_exists "$entrypoint" "差し替えられたentrypoint"
  assert_contains "$(cat "$entrypoint")" "利用者のentrypoint" "差し替え内容"
  assert_contains "$UNINSTALL_OUT$UNINSTALL_ERR" "差し替え" "安全側の警告"
  assert_file_exists "$TARGET/.token-saver/installed.json" "取り残し台帳"
}
