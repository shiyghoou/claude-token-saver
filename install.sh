#!/usr/bin/env bash
# claude-token-saver を導入先リポジトリへインストールする。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/install.sh
#   install.sh <導入先ディレクトリ>
#
# 冪等である。二度実行しても設定は重複しない。
# 環境変数 CTS_NO_SYMLINK=1 でスキルのリンクをコピーへ強制的に退避できる。
# 環境変数 CTS_STRICT=1 で、警告があれば終了コードを非 0 にする（CI 向け）。

set -uo pipefail

# 物理パスで解決する。シンボリックリンク経由で呼ばれたときに綴りの違う
# パスが登録され、実パス経由の再実行で二重登録になるのを防ぐ。
CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "${1:-$PWD}" >&2
  exit 1
}

# パスの単一情報源。
# shellcheck source=scripts/lib/paths.sh
. "$CTS_HOME/scripts/lib/paths.sh" || {
  printf 'エラー: scripts/lib/paths.sh を読めない（クローンが不完全である）\n' >&2
  exit 1
}

SETTINGS="$TARGET/.claude/settings.local.json"
BACKUP="$SETTINGS.cts-backup"
GITIGNORE="$TARGET/.gitignore"
# 何を設置したかの台帳。uninstall.sh はこれを正として取り外す。
# 記録が無いと、利用者が自分で張った同名のリンクまで巻き込んで消してしまう。
LEDGER="$TARGET/$(cts_ledger_rel)"

# ここまでに適用した作業。途中で失敗したときに、何が残っているかを伝える。
applied=()
warnings=()
backup_path=""

die() {
  printf 'エラー: %s\n' "$*" >&2
  if [ "${#applied[@]}" -gt 0 ]; then
    printf 'ここまで適用した:\n' >&2
    printf '  - %s\n' "${applied[@]}" >&2
    printf '復旧するには uninstall.sh を実行せよ: %s/uninstall.sh %s\n' "$CTS_HOME" "$TARGET" >&2
  fi
  exit 1
}
info() { printf '%s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  警告: %s\n' "$*"
}

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。フック自体は python3 に依存しない。"

info "claude-token-saver を導入する: $TARGET"

# --- 1. ディレクトリ ---------------------------------------------------------

mkdir -p "$TARGET/$(cts_handoff_rel)/pending" \
         "$TARGET/$(cts_handoff_rel)/consumed" \
         "$TARGET/$(cts_base_rel)" ||
  die "ディレクトリを作成できない"
applied+=("$(cts_base_rel)/ のディレクトリを作成")

# --- 1b. 旧パスからの移行 ----------------------------------------------------
# 引き継ぎと台帳は以前 .claude/ 配下にあった。台帳を読む前に移す。台帳自身が
# 移動対象であり、先に読むと旧版の記録を見落として二重登録になる。
#
# 上書きは絶対にしない。引き継ぎは作業の記録であり、失うと事故の調査ができない。
# 衝突した1件は旧側に残し、利用者へ判断を渡す。
#
# mv で移すため、シンボリックリンクは追わずリンク自体が移る。リンク先の検証は
# 読み取り時（scripts/handoff-check.sh）が担う。ここで実体化させると、
# その検証が空回りする。
#
# 塞いでいない狭い経路が1つある: 新版で install した後、同じ場所へ旧版の
# install.sh を実行すると、旧版は新パスの存在を知らないため旧パスへ台帳を
# 新規作成し、二重登録になる。次に新版の install.sh（またはこの移行）を
# 走らせると、新旧どちらにも台帳がある状態になり、上の「台帳が新旧の両方に
# あるため移していない」で warn するだけに留まり両方残る。さらに
# uninstall.sh は新パスの台帳を優先して読むため、旧台帳だけに記録された
# フックは外されない。version の逆行というこの経路自体が想定外の運用で
# あり、ここで自動修復はしない。起きた形跡（台帳が新旧両方にある）は
# 警告で見える設計になっている、という点だけ書き残す。
migrated=0
migrate_conflicts=0

cts_migrate_dir() {
  local from="$1" to="$2" entry base
  [ -d "$from" ] || return 0
  mkdir -p "$to" || die "移行先を作成できない: $to"
  for entry in "$from"/* "$from"/.*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
      . | ..) continue ;;
    esac
    if [ -e "$to/$base" ] || [ -L "$to/$base" ]; then
      migrate_conflicts=$((migrate_conflicts + 1))
      warn "移行先に同名があるため移していない: $to/$base（旧側に残した）"
      continue
    fi
    mv "$entry" "$to/$base" || die "移行できない: $entry"
    migrated=$((migrated + 1))
    # 移した直後に記録する。この後の別ファイルの移行が die しても、
    # 既に移した分を「ここまで適用した」一覧から漏らさないためである。
    # 完了を待ってからまとめて1件積むと、途中で die したときに
    # 何がどこへ移ったのか利用者に伝わらない。
    applied+=("旧パス（.claude 配下）から $to/$base へ移行")
  done
  return 0
}

cts_migrate_dir "$TARGET/$(cts_legacy_handoff_rel)/pending" \
                "$TARGET/$(cts_handoff_rel)/pending"
cts_migrate_dir "$TARGET/$(cts_legacy_handoff_rel)/consumed" \
                "$TARGET/$(cts_handoff_rel)/consumed"

# 台帳は1ファイルなので個別に扱う。
legacy_ledger="$TARGET/$(cts_legacy_ledger_rel)"
if [ -f "$legacy_ledger" ]; then
  if [ -e "$LEDGER" ]; then
    migrate_conflicts=$((migrate_conflicts + 1))
    warn "台帳が新旧の両方にあるため移していない: $legacy_ledger（旧側に残した）"
  else
    mkdir -p "$(dirname "$LEDGER")" || die "台帳の置き場所を作成できない"
    mv "$legacy_ledger" "$LEDGER" || die "台帳を移行できない"
    migrated=$((migrated + 1))
    applied+=("旧パスの台帳を $LEDGER へ移行")
  fi
fi

# 空になった旧ディレクトリだけ片付ける。rmdir は空でなければ何もしないため、
# 衝突で残した実ファイルは従来どおり残る。
rmdir "$TARGET/$(cts_legacy_handoff_rel)/pending" \
      "$TARGET/$(cts_legacy_handoff_rel)/consumed" 2>/dev/null || true
rmdir "$TARGET/$(cts_legacy_handoff_rel)" \
      "$TARGET/$(cts_legacy_state_rel)" 2>/dev/null || true

# 移行の対象は pending/ consumed/ installed.json の3つに限る（設計どおり）。
# それ以外の取り残し（例: 引き継ぎの器の直下に置かれた迷子の1ファイル）は
# rmdir を必ず失敗させ、器が残る。器が残ること自体は黙っていてよいが、その
# 中身が「新旧の gitignore ブロックのどちらにも書かれない」ことは黙っていては
# いけない。旧ブロックは install.sh がこの後 .gitignore を再生成する時点で
# 消える（新ブロックは新パスしか無視しない）ため、残った旧ディレクトリの
# 中身は次の git status で利用者に「新規の未追跡ファイル」として突然現れる。
# 衝突（同名がある）は既に warn 済みだが、衝突でない取りこぼし（同名が
# 無いのに移行対象外という理由だけで残った物）はここでしか気づけない。
legacy_leftover=""
[ -e "$TARGET/$(cts_legacy_handoff_rel)" ] && legacy_leftover="$legacy_leftover $(cts_legacy_handoff_rel)"
[ -e "$TARGET/$(cts_legacy_state_rel)" ] && legacy_leftover="$legacy_leftover $(cts_legacy_state_rel)"
if [ -n "$legacy_leftover" ]; then
  warn "旧パスに未移行のファイルが残っている（pending/consumed/installed.json 以外は移行対象外である）:$legacy_leftover"
fi

# applied への記録は各ファイル・台帳を移した直後に済んでいる（die 時に漏れ
# させないため）。ここでは締めくくりとして利用者向けに件数を要約するだけで、
# applied への追記はしない。移した件数だけでなく、衝突で旧側に残した件数も
# 伝える。migrate_conflicts を数えるだけで語らないと、利用者は何件が衝突した
# のか警告メッセージを1つずつ数えるしかなくなる。
if [ "$migrated" -gt 0 ] || [ "$migrate_conflicts" -gt 0 ]; then
  info "旧パス（.claude 配下）からの移行: $migrated 件を移行、$migrate_conflicts 件は衝突のため旧側に残した"
fi

# .gitignore を新規に作るかどうかは、この時点でしか分からない。
# uninstall.sh が「空になったから消してよい」と判断する根拠になる。
gitignore_existed=1
[ -e "$GITIGNORE" ] || gitignore_existed=0

# --- 2. フックの登録 ---------------------------------------------------------

# 実体のあるスクリプトだけを登録する。存在しないコマンドを登録すると、
# 導入先のセッションでフックが毎回失敗する。
hook_specs=()
if [ -f "$CTS_HOME/scripts/handoff-check.sh" ]; then
  hook_specs+=("SessionStart:$CTS_HOME/scripts/handoff-check.sh")
else
  warn "scripts/handoff-check.sh が無いため SessionStart フックを登録しない（クローンが不完全である）"
fi
# suggest-session-cut.sh は段階3の成果物である。まだ無いのが正常なので、
# 取りこぼしの警告ではなく予定として伝える。
if [ -f "$CTS_HOME/scripts/suggest-session-cut.sh" ]; then
  hook_specs+=("Stop:$CTS_HOME/scripts/suggest-session-cut.sh")
else
  info "  Stop フック（セッション区切りの提案）は段階3で登録される"
fi

if [ "${#hook_specs[@]}" -gt 0 ]; then
  # settings.local.json は通常 git 管理外の個人設定である。git から復元でき
  # ないので、最初の書き換え前に控えを取る。既にあれば上書きしない（原状の
  # 控えを、再実行で自分の書いた内容へ塗り替えては意味がない）。
  # 既にあれば上書きしないのは意図である。控えの値打ちは「導入より前の内容」で
  # あることに尽きる。再実行で更新すると、自分が書いた内容へ塗り替わって
  # 復旧手段が失われる。既存の控えが壊れた JSON の写しであっても、それが
  # 原状であるから直すのは原本のほうであり、控えを作り直す話ではない。
  if [ -f "$SETTINGS" ] && [ ! -e "$BACKUP" ]; then
    cp -p "$SETTINGS" "$BACKUP" || die "settings.local.json の控えを作れない"
    backup_path="$BACKUP"
    # 控えは settings.local.json の書き換えより前に作られるため、この後で
    # die しても残る。applied に載せなければ、利用者は残ったことを知らない。
    applied+=("settings.local.json の控えを作成（導入前の内容）: $BACKUP")
  fi

  python3 "$CTS_HOME/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$LEDGER" "${hook_specs[@]}" ||
    die "settings.local.json または台帳を更新できない"
  applied+=("settings.local.json へフックを登録")
fi

# --- 3. スキルのリンク -------------------------------------------------------

# 実体はクローン先に1つだけ置く。複数プロジェクトへ導入しても更新は git pull 1回で全体へ届く。
mkdir -p "$TARGET/.claude/skills" || die "skills ディレクトリを作成できない"

# 実際に設置したスキルだけを .gitignore へ書くため、名前を集める。
installed_skills=()
found_skills=0

# 台帳が無い旧環境向けの推測。リンク先が「どこかのクローンの skills/<同名>」で
# あり、その親に install.sh が実在するときだけ自分のものとみなす。
# basename と親ディレクトリ名だけで判定すると、利用者が社内共有の skills/ へ
# 張ったリンクまで自分のものと誤認する。
looks_like_our_link() {
  local link="$1" name="$2" home
  [ "$(basename "$link")" = "$name" ] || return 1
  [ "$(basename "$(dirname "$link")")" = "skills" ] || return 1
  home="$(dirname "$(dirname "$link")")"
  [ -f "$home/install.sh" ]
}

for skill_dir in "$CTS_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  found_skills=$((found_skills + 1))
  name="$(basename "$skill_dir")"
  dest="$TARGET/.claude/skills/$name"
  src="${skill_dir%/}"

  # 既に正しくリンクされているなら何もしない。
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    installed_skills+=("$name")
    python3 "$CTS_HOME/lib/ledger.py" add-skill "$LEDGER" "$name" "$src" link ||
      die "台帳を更新できない"
    continue
  fi

  if [ -L "$dest" ]; then
    # 別の場所を指すリンク。自分が過去に張ったもの（クローンを移した等）なら
    # 張り替える。そうでなければ導入先の設置物なので触らない。
    link="$(readlink "$dest")"
    # 区切りは US(0x1f)。ledger.py の行プロトコルと合わせる。
    recorded="$(python3 "$CTS_HOME/lib/ledger.py" get-skill "$LEDGER" "$name" | cut -d $'\037' -f1)"
    if [ -n "$recorded" ] && [ "$recorded" = "$link" ]; then
      : # 自分が張ったリンクである
    elif [ -z "$recorded" ] && looks_like_our_link "$link" "$name"; then
      : # 台帳の無い旧環境で張ったリンクとみなす
    else
      warn "スキル $name は導入先が張ったリンクなので触らない（$link）"
      continue
    fi
  elif [ -d "$dest" ]; then
    # 実ディレクトリがあり、それが install.sh のコピーでないなら触らない。
    # 導入先が自前で置いたスキルを上書きすると、他人の作業を消す。
    if [ ! -f "$dest/.claude-token-saver" ]; then
      warn "スキル $name は導入先に既存のディレクトリがあるため触らない（.gitignore にも書かない）"
      continue
    fi
  elif [ -e "$dest" ]; then
    # リンクでもディレクトリでもない既存物（通常ファイル・FIFO など）。
    # 分岐がリンクとディレクトリしか見ていないと、これが下の rm -rf へ落ちて
    # 利用者のファイルを無警告で消す。知らない種類のものには触らない。
    warn "スキル $name は導入先に既存のファイルがあるため触らない（.gitignore にも書かない）"
    continue
  fi

  rm -rf "$dest"
  mode=link
  if [ -z "${CTS_NO_SYMLINK:-}" ] && ln -s "$src" "$dest" 2>/dev/null; then
    info "  スキルをリンクした: $name"
  else
    cp -R "$src" "$dest" || die "スキル $name を配置できない"
    # コピーであることを記録する。次回の install.sh が更新してよいと判断できるようにする。
    printf 'claude-token-saver が配置したコピー。手で編集しない。\n' >"$dest/.claude-token-saver"
    mode=copy
    info "  スキルをコピーで配置した（シンボリックリンクが使えない環境）: $name"
    info "    リポジトリを更新したら install.sh を再実行してコピーを更新せよ。"
  fi
  python3 "$CTS_HOME/lib/ledger.py" add-skill "$LEDGER" "$name" "$src" "$mode" ||
    die "台帳を更新できない"
  installed_skills+=("$name")
  applied+=("スキル $name を設置")
done

[ "$found_skills" -gt 0 ] ||
  warn "skills/ にスキルが1つも無いため何も設置していない（クローンが不完全である）"

# --- 4. .gitignore -----------------------------------------------------------

# 引き継ぎと状態ファイルは利用実績であり、既定では版管理しない。
# スキルのリンクは絶対パスを指す環境依存の産物であり、版管理へ入れると
# 他の開発者のクローンで壊れたリンクになる。
#
# ブロックは毎回作り直す。存在確認だけで済ませると、スキルが増えたときに
# 無視行が追加されず、リンクが版管理対象として現れる。
# 無視行を書くのは実際に設置したスキルだけに限る。触らなかったスキル
# （導入先が自前で持っているもの）を無視すると、その版管理を静かに壊す。
{
  printf '%s/\n' "$(cts_base_rel)"
  for name in ${installed_skills[@]+"${installed_skills[@]}"}; do
    printf '.claude/skills/%s\n' "$name"
  done
} | python3 "$CTS_HOME/lib/gitignore-block.py" apply "$GITIGNORE"
gitignore_status=$?
case "$gitignore_status" in
  # applied は失敗時の唯一の説明手段である。実際に書いたときだけ積む。
  0) applied+=(".gitignore を更新") ;;
  3) ;;
  2) warnings+=(".gitignore の claude-token-saver ブロックが壊れているため更新していない") ;;
  *) die ".gitignore を更新できない" ;;
esac

# 自分で作った .gitignore だけを、取り外しのときに消してよい。
if [ "$gitignore_existed" = 0 ] && [ -e "$GITIGNORE" ]; then
  python3 "$CTS_HOME/lib/ledger.py" set-flag "$LEDGER" gitignore_created 1 ||
    die "台帳を更新できない"
fi

# --- 5. まとめ ---------------------------------------------------------------

[ -n "$backup_path" ] && info "  既存の settings.local.json の控え: $backup_path"

if [ "${#warnings[@]}" -gt 0 ]; then
  info ""
  info "警告 ${#warnings[@]} 件（未適用の項目がある）:"
  printf '  - %s\n' "${warnings[@]}"
  info "内容を確認せよ。取り消すには uninstall.sh を実行する。"
  # CI から呼ぶと、未適用のまま rc=0 で通ってしまう。明示的に厳格を選べるようにする。
  [ -n "${CTS_STRICT:-}" ] && exit 1
else
  info "完了。新しいセッションを開始すると引き継ぎフックが有効になる。"
fi
exit 0
