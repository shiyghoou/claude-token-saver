#!/usr/bin/env bash
# install.sh を取り消す。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/uninstall.sh
#   uninstall.sh [--personal|--shared] [--guess] [<導入先ディレクトリ>]
#
# .token-saver/handoff/ 配下の実ファイルは消さない。引き継ぎは作業の記録であり、
# アンインストールで失われてよいものではない。
#
# 何を外すかは台帳（.token-saver/installed.json）を正とする。
# 台帳に記録が無ければ何もしない（fail-closed）。推測で外すと、利用者が自分で
# 張った同名のリンクや自作のフックを巻き込んで消す。台帳の無い旧版で導入した
# 環境のために --guess を用意する。それを付けたときだけ従来の推測へ落ちる。
#
#   uninstall.sh [--personal|--shared] [--guess] [<導入先ディレクトリ>]
#
# 環境変数 CTS_STRICT=1 で、警告があれば終了コードを非 0 にする（CI 向け）。

set -uo pipefail

# 台帳の行プロトコルのフィールド区切り（US, 0x1f）。lib/ledger.py と合わせる。
# tab を使ってはならない。tab は IFS の空白文字であるため read が連続する
# 区切りを畳み、空フィールドが次のフィールドの値へ化ける。

CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

GUESS=0
scope_arg=""
pos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --personal | --shared)
      if [ -n "$scope_arg" ]; then
        printf 'エラー: スコープは --personal または --shared のいずれか1つだけ指定できる\n' >&2
        exit 1
      fi
      scope_arg="$1"
      ;;
    --guess) GUESS=1 ;;
    -h | --help)
      printf 'usage: uninstall.sh [--personal|--shared] [--guess] [<導入先ディレクトリ>]\n'
      printf '  --personal  個人設定・フック・スキル・状態だけを外す\n'
      printf '  --shared    .gitignoreだけを外す\n'
      printf '  --guess     台帳の無い旧環境を推測して外す（個人側のみ）\n'
      exit 0
      ;;
    -*)
      printf 'エラー: 不明なオプション: %s\n' "$1" >&2
      exit 1
      ;;
    *) pos+=("$1") ;;
  esac
  shift
done
do_personal=1
do_shared=1
case "$scope_arg" in
  --personal) do_shared=0 ;;
  --shared) do_personal=0 ;;
esac
if [ "$scope_arg" = "--shared" ] && [ "$GUESS" = 1 ]; then
  printf 'エラー: --guess は --personal スコープでのみ指定できる\n' >&2
  exit 1
fi
target_arg="${pos[0]:-$PWD}"
if [ "${#pos[@]}" -gt 1 ]; then
  printf 'エラー: 導入先ディレクトリは1つだけ指定できる\n' >&2
  exit 1
fi

TARGET="$(cd -- "$target_arg" 2>/dev/null && pwd -P)" || {
  printf 'エラー: 導入先ディレクトリが見つからない: %s\n' "$target_arg" >&2
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
LEDGER="$TARGET/$(cts_ledger_rel)"
TOKEN_REPORT_ENTRYPOINT="$TARGET/$(cts_token_report_rel)"
TOKEN_CALIBRATE_ENTRYPOINT="$TARGET/$(cts_token_calibrate_rel)"
# 案内するパスは、実際に読んだ台帳のものでなければならない。旧パスへ
# フォールバックしたときに新パスを案内すると、利用者が消す先を間違える。
LEDGER_REL="$(cts_ledger_rel)"

warnings=()

die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  警告: %s\n' "$*"
}

cts_reject_managed_symlinks() {
  local path
  for path in \
    "$TARGET/.agents" \
    "$TARGET/.agents/skills" \
    "$TARGET/.claude" \
    "$TARGET/.claude/skills" \
    "$TARGET/$(cts_legacy_handoff_rel)" \
    "$TARGET/$(cts_legacy_handoff_rel)/pending" \
    "$TARGET/$(cts_legacy_handoff_rel)/consumed" \
    "$TARGET/$(cts_legacy_state_rel)" \
    "$TARGET/$(cts_handoff_rel)" \
    "$TARGET/$(cts_handoff_rel)/pending" \
    "$TARGET/$(cts_handoff_rel)/consumed" \
    "$TARGET/$(cts_base_rel)"; do
    if [ -L "$path" ]; then
      die "管理対象ディレクトリのシンボリックリンクを辿らない: $path"
    fi
  done
}

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json と .gitignore を壊さずに編集するため）。"

[ "$do_personal" = 1 ] && cts_reject_managed_symlinks

info "claude-token-saver を取り外す: $TARGET"

# 「台帳ファイルが在る」と「台帳に記録が在る」は別である。空の台帳や壊れた
# 台帳をファイルの有無だけで「在る」と数えると、記録ゼロを「設置物ゼロ」と
# 取り違え、外すべきものを残したまま「完了。」と言う。
# 判定は lib/ledger.py に寄せる（JSON を読めるのは python 側だけである）。
#
# 新パスに台帳が無く、旧パス（.claude 配下）にあるなら、そちらを読む。
# 旧版で導入したあと新版で取り外す経路である。フォールバックが無いと台帳を
# 見つけられず、fail-closed で利用者のフックを残したまま終わる。
# 読むだけで、旧台帳へは書き込まない。旧パスは移行元であり、書き戻すと
# install.sh の移行が次回また同じものを拾う。
LEGACY_LEDGER="$TARGET/$(cts_legacy_ledger_rel)"
if ! python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" any &&
   python3 "$CTS_HOME/lib/ledger.py" has-record "$LEGACY_LEDGER" any; then
  info "  旧パスの台帳を使う: $(cts_legacy_ledger_rel)"
  LEDGER="$LEGACY_LEDGER"
  LEDGER_REL="$(cts_legacy_ledger_rel)"
fi

have_ledger=0
have_skill_record=0
python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" any && have_ledger=1
python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" skills && have_skill_record=1
token_report_source="$(python3 "$CTS_HOME/lib/ledger.py" get-value "$LEDGER" token_report_source)"
token_calibrate_source="$(python3 "$CTS_HOME/lib/ledger.py" get-value "$LEDGER" token_calibrate_source)"

# 外せなかった・触らなかった設置物が Claude Code / Codex の skills destination に残っているか。
# 残っているなら .gitignore の除外を外してはならない（絶対パスのリンクが
# 未追跡ファイルとして git に現れる）。
skills_left=0
token_report_left=0
token_calibrate_left=0

if [ "$do_personal" = 1 ]; then

# --- 1b. target-local token-report entrypoint --------------------------------

# shellcheck source=scripts/lib/token-report-entrypoint.sh
. "$CTS_HOME/scripts/lib/token-report-entrypoint.sh" ||
  die "scripts/lib/token-report-entrypoint.sh を読めない（クローンが不完全である）"

if [ -n "$token_report_source" ]; then
  if [ -L "$TOKEN_REPORT_ENTRYPOINT" ] ||
     { [ -e "$TOKEN_REPORT_ENTRYPOINT" ] && [ ! -f "$TOKEN_REPORT_ENTRYPOINT" ]; }; then
    warn "token-report entrypoint は導入後に差し替えられているので残す"
    token_report_left=1
  elif [ -f "$TOKEN_REPORT_ENTRYPOINT" ]; then
    expected_entrypoint="$(mktemp "${TMPDIR:-/tmp}/cts-token-report-entrypoint.XXXXXX")" ||
      die "entrypoint の所有権を検証する一時ファイルを作成できない"
    cts_write_token_report_entrypoint "$expected_entrypoint" "$token_report_source" || {
      rm -f "$expected_entrypoint"
      die "entrypoint の所有権を検証できない"
    }
    if cmp -s "$expected_entrypoint" "$TOKEN_REPORT_ENTRYPOINT"; then
      rm -f "$TOKEN_REPORT_ENTRYPOINT"
      info "  token-report の入口を外した"
    else
      warn "token-report entrypoint は導入後に差し替えられているので残す"
      token_report_left=1
    fi
    rm -f "$expected_entrypoint"
  fi
elif [ -e "$TOKEN_REPORT_ENTRYPOINT" ] || [ -L "$TOKEN_REPORT_ENTRYPOINT" ]; then
  warn "台帳に token-report entrypoint の記録が無いため触らない"
  token_report_left=1
fi

# --- 1c. target-local token-calibrate entrypoint -----------------------------

# shellcheck source=scripts/lib/token-calibrate-entrypoint.sh
. "$CTS_HOME/scripts/lib/token-calibrate-entrypoint.sh" ||
  die "scripts/lib/token-calibrate-entrypoint.sh を読めない（クローンが不完全である）"

if [ -n "$token_calibrate_source" ]; then
  if [ -L "$TOKEN_CALIBRATE_ENTRYPOINT" ] ||
     { [ -e "$TOKEN_CALIBRATE_ENTRYPOINT" ] && [ ! -f "$TOKEN_CALIBRATE_ENTRYPOINT" ]; }; then
    warn "token-calibrate entrypoint は導入後に差し替えられているので残す"
    token_calibrate_left=1
  elif [ -f "$TOKEN_CALIBRATE_ENTRYPOINT" ]; then
    expected_entrypoint="$(mktemp "${TMPDIR:-/tmp}/cts-token-calibrate-entrypoint.XXXXXX")" ||
      die "token-calibrate entrypoint の所有権を検証する一時ファイルを作成できない"
    cts_write_token_calibrate_entrypoint "$expected_entrypoint" "$token_calibrate_source" || {
      rm -f "$expected_entrypoint"
      die "token-calibrate entrypoint の所有権を検証できない"
    }
    if cmp -s "$expected_entrypoint" "$TOKEN_CALIBRATE_ENTRYPOINT"; then
      rm -f "$TOKEN_CALIBRATE_ENTRYPOINT"
      info "  token-calibrate の入口を外した"
    else
      warn "token-calibrate entrypoint は導入後に差し替えられているので残す"
      token_calibrate_left=1
    fi
    rm -f "$expected_entrypoint"
  fi
elif [ -e "$TOKEN_CALIBRATE_ENTRYPOINT" ] || [ -L "$TOKEN_CALIBRATE_ENTRYPOINT" ]; then
  warn "台帳に token-calibrate entrypoint の記録が無いため触らない"
  token_calibrate_left=1
fi

# --- 1. フックの登録解除 -----------------------------------------------------

# 台帳に記録した登録コマンドと一致するものを外す。記録が無ければ何もしない。
# --guess のときだけファイル名で推測する（利用者の自作を巻き込みうる）。
# 判定は install.sh と共有する（lib/settings-hooks.py）。
if [ -f "$SETTINGS" ]; then
  guess_opt=()
  [ "$GUESS" = 1 ] && guess_opt=(--guess)
  python3 "$CTS_HOME/lib/settings-hooks.py" remove "$SETTINGS" \
    --ledger "$LEDGER" ${guess_opt[0]+"${guess_opt[@]}"}
  case "$?" in
    0) ;;
    2) warnings+=("台帳にフックの記録が無いため settings.local.json を変更していない（--guess で推測できる）") ;;
    *) die "settings.local.json を更新できない" ;;
  esac
else
  info "  settings.local.json が無い"
fi

# --- 2. スキル ---------------------------------------------------------------

# 台帳が無い旧環境向けの推測。リンク先が「どこかのクローンの skills/<同名>」で
# あり、その親に install.sh が実在するときだけ自分のものとみなす。
# basename と親ディレクトリ名だけで判定すると、利用者が社内共有の skills/ へ
# 張ったリンクまで削除してしまう。
looks_like_our_link() {
  local link="$1" name="$2" home
  [ "$(basename "$link")" = "$name" ] || return 1
  [ "$(basename "$(dirname "$link")")" = "skills" ] || return 1
  home="$(dirname "$(dirname "$link")")"
  [ -f "$home/install.sh" ]
}

# 設置したものだけを外す。dest が記録どおりでなければ、導入後に導入先が
# 差し替えたということなので触らない。Claude Code と Codex は別々の
# destination として検査し、片方の取り残しがもう片方の取り外しを妨げない。
remove_skill_destination() {
  local name="$1" src="$2" dest="$3" runtime_label="$4"
  if [ -L "$dest" ]; then
    # src が空の記録は「何を指していたか分からない」ということである。
    # それを無条件削除の許可と読み替えると、利用者のリンクを消しうる。
    if [ -z "$src" ]; then
      warn "$runtime_label スキル $name の記録にリンク先が無いため触らない"
      skills_left=1
      return 0
    fi
    if [ "$(readlink "$dest")" = "$src" ]; then
      rm -f "$dest"
      info "  $runtime_label スキルのリンクを外した: $name"
      return 0
    fi
  elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
    rm -rf "$dest"
    info "  $runtime_label スキルのコピーを削除した: $name"
    return 0
  elif [ ! -e "$dest" ]; then
    return 0
  fi
  warn "$runtime_label スキル $name は導入後に差し替えられているので残す"
  skills_left=1
}

remove_skill() {
  local name="$1" src="$2" codex_dest
  # 台帳の name はそのままパスへ連結される。/ や .. を通すと導入先の外の
  # リンクまで削除できる。台帳は自分が書いたものだが、手で編集もされうるので
  # 読む側でも検証する（ledger.py 側と二重に持つのは、どちらか一方の
  # 綴りを変えたときに穴が開かないようにするためである）。
  case "$name" in
    "" | . | .. | */*)
      warn "台帳のスキル名が不正なので触らない: $name"
      return 0
      ;;
  esac
  remove_skill_destination "$name" "$src" \
    "$TARGET/.claude/skills/$name" "Claude Code"

  codex_dest="$TARGET/.agents/skills/$name"
  if [ -e "$codex_dest" ] || [ -L "$codex_dest" ]; then
    # Codex destination は source metadata があるときだけ所有権を検査する。
    # source clone が消費・変更された場合に、記録だけを根拠に削除してはならない。
    if [ -z "$src" ] || [ ! -f "$src/agents/openai.yaml" ]; then
      warn "Codex スキル $name のsource metadataを確認できないため残す"
      skills_left=1
    else
      remove_skill_destination "$name" "$src" "$codex_dest" "Codex"
    fi
  fi
}

if [ "$have_skill_record" = 1 ]; then
  # 区切りは US(0x1f)。tab は IFS の空白文字であり、連続する区切りが1つに
  # 畳まれて空フィールドが表現できない（空の src が mode の値へ化ける）。
  while IFS=$'\037' read -r name src _mode; do
    [ -n "$name" ] || continue
    remove_skill "$name" "$src"
  done < <(python3 "$CTS_HOME/lib/ledger.py" list-skills "$LEDGER")
elif [ "$GUESS" = 0 ]; then
  # 記録が無い。推測すると利用者が自分で張った同名のリンクを消すため、
  # 既定では何もしない。残っている設置物は .gitignore の除外ごと残す。
  if [ -d "$TARGET/.claude/skills" ] &&
     [ -n "$(find "$TARGET/.claude/skills" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    warn "台帳にスキルの記録が無いため .claude/skills を変更していない（--guess で推測できる）"
    skills_left=1
  fi
  if [ -d "$TARGET/.agents/skills" ] &&
     [ -n "$(find "$TARGET/.agents/skills" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    warn "台帳にスキルの記録が無いため .agents/skills を変更していない（--guess ではCodexを推測しない）"
    skills_left=1
  fi
elif [ -d "$TARGET/.claude/skills" ]; then
  # 台帳が無い。導入先の skills を走査して推測する。
  for dest in "$TARGET/.claude/skills"/*; do
    [ -e "$dest" ] || [ -L "$dest" ] || continue
    name="$(basename "$dest")"

    if [ -L "$dest" ]; then
      if looks_like_our_link "$(readlink "$dest")" "$name"; then
        rm -f "$dest"
        info "  スキルのリンクを外した: $name"
      else
        info "  スキル $name は導入先のものなので残す"
      fi
    elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
      rm -rf "$dest"
      info "  スキルのコピーを削除した: $name"
    fi
  done
fi

# --guess は従来の Claude destination だけを対象とする。Codex destination は
# source metadata と台帳が無い状態で推測削除すると、利用者のリンクやコピーを
# 巻き込むため、存在を警告して残す。
if [ "$have_skill_record" = 0 ] && [ "$GUESS" = 1 ] &&
   [ -d "$TARGET/.agents/skills" ] &&
   [ -n "$(find "$TARGET/.agents/skills" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  warn "--guess では Codex の .agents/skills を推測削除しない"
  skills_left=1
fi

# 空になった skills ディレクトリは片付ける。中身があるなら触らない。
# 一度も導入していない導入先の空ディレクトリへ手を出さないため、
# 記録がある（＝ここへ導入した）ときだけ片付ける。
if [ "$have_ledger" = 1 ] || [ "$GUESS" = 1 ]; then
  rmdir "$TARGET/.claude/skills" 2>/dev/null || true
  rmdir "$TARGET/.agents/skills" 2>/dev/null || true
  rmdir "$TARGET/.agents" 2>/dev/null || true
fi

fi

# --- 3. .gitignore -----------------------------------------------------------

handoff_dir="$TARGET/$(cts_handoff_rel)"
legacy_handoff_dir="$TARGET/$(cts_legacy_handoff_rel)"
state_dir="$TARGET/$(cts_base_rel)"
shared_left=0
shared_skill_ledger="$TARGET/$(cts_ledger_rel)"
shared_have_skill_record=0
if python3 "$CTS_HOME/lib/ledger.py" has-record "$shared_skill_ledger" skills; then
  shared_have_skill_record=1
elif python3 "$CTS_HOME/lib/ledger.py" has-record "$LEGACY_LEDGER" skills; then
  shared_skill_ledger="$LEGACY_LEDGER"
  shared_have_skill_record=1
fi

if [ "$do_shared" = 1 ] && [ "$do_personal" = 0 ]; then
  # 共有設定だけを外すときは個人領域を変更しない。台帳に記録されたスキル、
  # 状態ファイル、引き継ぎ、token-report の入口が残るなら、除外を外して
  # 未追跡ファイルを露出させない。
  if [ "$shared_have_skill_record" = 1 ]; then
    while IFS=$'\037' read -r name _src _mode; do
      case "$name" in
        "" | . | .. | */*)
          [ -z "$name" ] || {
            warn "台帳のスキル名が不正なので .gitignore の除外を外さない: $name"
            shared_left=1
          }
          ;;
        *)
          dest="$TARGET/.claude/skills/$name"
          if [ -e "$dest" ] || [ -L "$dest" ]; then
            shared_left=1
          fi
          dest="$TARGET/.agents/skills/$name"
          if [ -e "$dest" ] || [ -L "$dest" ]; then
            shared_left=1
          fi
          ;;
      esac
    done < <(python3 "$CTS_HOME/lib/ledger.py" list-skills "$shared_skill_ledger")
  fi

  for state_candidate in "$state_dir" "$TARGET/$(cts_legacy_state_rel)" \
    "$handoff_dir" "$legacy_handoff_dir"; do
    if [ -L "$state_candidate" ]; then
      shared_left=1
    elif [ -d "$state_candidate" ] &&
         [ -n "$(find "$state_candidate" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; then
      shared_left=1
    fi
  done
fi

# スキルより後に処理する。除外を外してから設置物を残すと、絶対パスのリンクが
# 未追跡ファイルとして git に現れ、利用者の作業を汚す。
# ブロックは START/END マーカーで自分のものと確定できるため、台帳の有無には
# 依存しない（推測ではない）。
if [ "$do_shared" = 1 ]; then
  if { [ "$do_personal" = 1 ] &&
       { [ "$skills_left" = 1 ] || [ "$token_report_left" = 1 ] ||
         [ "$token_calibrate_left" = 1 ]; }; } ||
     { [ "$do_personal" = 0 ] && [ "$shared_left" = 1 ]; }; then
    warn "管理対象の設置物が残っているため .gitignore の除外を外していない"
  elif [ -f "$GITIGNORE" ]; then
    python3 "$CTS_HOME/lib/gitignore-block.py" remove "$GITIGNORE"
    case "$?" in
      0) ;;
      2) warnings+=(".gitignore のブロックが不正または改行形式が混在しているため削除していない") ;;
      *) die ".gitignore を更新できない" ;;
    esac
  fi
fi

# --- 4. 残したものの通知と後片付け -------------------------------------------

if [ "$do_personal" = 1 ]; then

# .gitignore を消してよいかは、install.sh が作ったかどうかで決まる。
# 追跡済みの空の .gitignore を消すと、利用者のコミットから勝手に消える。
gitignore_created=0
[ "$have_ledger" = 1 ] &&
  gitignore_created="$(python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" gitignore_created)"
settings_created=0
[ "$have_ledger" = 1 ] &&
  settings_created="$(python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" settings_created)"

# 台帳は、外し切れたときだけ役目を終える。取り残しがあるのに消すと、次回の
# 実行が「記録の無い状態」＝何もできない状態になり、取り外し不能になる。
# 無条件に消していた頃は、2回目が必ず推測経路へ落ちていた。
if [ "${#warnings[@]}" -eq 0 ]; then
  rm -f "$LEDGER"
else
  info "  取り残しがあるため台帳を残した: $LEDGER_REL"
fi

handoff_dir="$TARGET/$(cts_handoff_rel)"
legacy_handoff_dir="$TARGET/$(cts_legacy_handoff_rel)"
handoff_notice=""
for candidate_handoff in "$handoff_dir" "$legacy_handoff_dir"; do
  if [ -d "$candidate_handoff" ] &&
     [ -n "$(find "$candidate_handoff" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; then
    if [ "$candidate_handoff" = "$handoff_dir" ]; then
      handoff_notice="$handoff_notice $(cts_handoff_rel)"
    else
      handoff_notice="$handoff_notice $(cts_legacy_handoff_rel)"
    fi
  fi
done
if [ -n "$handoff_notice" ]; then
  info ""
  info "引き継ぎのファイルは残した:$handoff_notice"
  info "  作業の記録であるため、アンインストールでは削除しない。不要なら手で削除せよ。"
  info "  .gitignore の除外は外れているので、版管理から外したいなら注意せよ。"
fi

state_dir="$TARGET/$(cts_base_rel)"
# -maxdepth 1: .token-saver/ は handoff/ を内包するようになった。付けないと、
# 引き継ぎが残っているだけで「状態ファイルは残した」と二重に案内する。
if [ -d "$state_dir" ] && [ -n "$(find "$state_dir" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
  info "状態ファイルは残した: $(cts_base_rel)"
fi

# 以降は、器そのものを消す後片付けである。ここへ導入した記録が無い相手に
# 対して実行してはならない。一度も導入していないリポジトリで uninstall しても
# 利用者の空の .claude/ や {} だけの settings.local.json が消える、という
# 事故がここで起きていた。
if [ "$have_ledger" = 1 ] || [ "$GUESS" = 1 ]; then
  # install.sh が作った空の器を残さない。rmdir は空でなければ何もしないので、
  # 実ファイルのある引き継ぎは従来どおり残る。深い側から順に消す。
  # $state_dir は $handoff_dir の親であるため、handoff を消した後に消す必要が
  # ある。1つの rmdir 呼び出しに並べても引数の順に処理されるとはいえ、
  # 意図を読み違えやすいので行を分ける。
  rmdir "$handoff_dir/pending" "$handoff_dir/consumed" 2>/dev/null || true
  rmdir "$handoff_dir" 2>/dev/null || true
  rmdir "$state_dir" 2>/dev/null || true

  # 旧パスの器も同様に片付ける。旧台帳フォールバックで空になった器を残すと、
  # 直後の rmdir "$TARGET/.claude" が「空でない」ため常に失敗し、旧経路だけ
  # アンインストール後の git status が導入前と一致しないままになる。
  rmdir "$TARGET/$(cts_legacy_state_rel)" 2>/dev/null || true

  # 中身が無くなったファイルのうち、install.sh より前には無かったものを消す。
  # install.sh が作ったものでも、利用者がその後コミットしていれば消さない。
  # 台帳のフラグは「作った」しか語らず、現在の追跡状態を語らないためである。
  if [ "$do_shared" = 1 ] && [ "$gitignore_created" = 1 ] &&
     [ -f "$GITIGNORE" ] && [ ! -s "$GITIGNORE" ]; then
    if git -C "$TARGET" ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
      info "  .gitignore は空になったが版管理されているため残した"
    else
      rm -f "$GITIGNORE"
    fi
  fi
  if [ "$settings_created" = 1 ] && [ -f "$SETTINGS" ] &&
     ! git -C "$TARGET" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1 &&
     [ "$(tr -d ' \t\n\r' <"$SETTINGS")" = "{}" ]; then
    rm -f "$SETTINGS"
  fi

  # 控えは、原状へ戻っているなら不要である。個人設定のコピーを黙って
  # 置き去りにすると、.claude/ を版管理している利用者が誤ってコミットしうる。
  if [ -e "$BACKUP" ]; then
    if python3 "$CTS_HOME/lib/settings-hooks.py" same "$SETTINGS" "$BACKUP"; then
      rm -f "$BACKUP"
    else
      info "  settings.local.json が控えと異なるため、控えを残した: $BACKUP"
      info "    導入後に設定を変えている。不要なら手で削除せよ。"
    fi
  fi

  rmdir "$TARGET/.claude" 2>/dev/null || true
fi

fi

if [ "${#warnings[@]}" -gt 0 ]; then
  info ""
  info "警告 ${#warnings[@]} 件（外し切れていない項目がある）:"
  printf '  - %s\n' "${warnings[@]}"
  info "内容を確認せよ。"
  [ -n "${CTS_STRICT:-}" ] && exit 1
else
  info "完了。"
fi
exit 0
