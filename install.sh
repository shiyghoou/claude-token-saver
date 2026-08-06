#!/usr/bin/env bash
# claude-token-saver を導入先リポジトリへインストールする。
#
#   cd <導入先リポジトリ> && /path/to/claude-token-saver/install.sh
#   install.sh [--personal|--shared] <導入先ディレクトリ>
#
# 冪等である。二度実行しても設定は重複しない。
# 環境変数 CTS_NO_SYMLINK=1 でスキルのリンクをコピーへ強制的に退避できる。
# 環境変数 CTS_STRICT=1 で、警告があれば終了コードを非 0 にする（CI 向け）。

set -uo pipefail

# 物理パスで解決する。シンボリックリンク経由で呼ばれたときに綴りの違う
# パスが登録され、実パス経由の再実行で二重登録になるのを防ぐ。
CTS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
scope_arg=""
target_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --personal | --shared)
      if [ -n "$scope_arg" ]; then
        printf 'エラー: スコープは --personal または --shared のいずれか1つだけ指定できる\n' >&2
        exit 1
      fi
      scope_arg="$1"
      ;;
    -h | --help)
      printf 'usage: install.sh [--personal|--shared] [<導入先ディレクトリ>]\n'
      printf '  --personal  個人設定・フック・スキル・状態だけを更新する\n'
      printf '  --shared    .gitignoreだけを更新する\n'
      printf '  （オプションなしは従来どおり両方を更新する）\n'
      exit 0
      ;;
    -*)
      printf 'エラー: 不明なオプション: %s\n' "$1" >&2
      exit 1
      ;;
    *) target_args+=("$1") ;;
  esac
  shift
done
do_personal=1
do_shared=1
case "$scope_arg" in
  --personal) do_shared=0 ;;
  --shared) do_personal=0 ;;
esac
if [ "${#target_args[@]}" -gt 1 ]; then
  printf 'エラー: 導入先ディレクトリは1つだけ指定できる\n' >&2
  exit 1
fi
target_arg="${target_args[0]:-$PWD}"
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
CODEX_DIR="$TARGET/.codex"
CODEX_HOOKS="$CODEX_DIR/hooks.json"
GITIGNORE="$TARGET/.gitignore"
# 何を設置したかの台帳。uninstall.sh はこれを正として取り外す。
# 記録が無いと、利用者が自分で張った同名のリンクまで巻き込んで消してしまう。
LEDGER="$TARGET/$(cts_ledger_rel)"
TOKEN_REPORT_ENTRYPOINT="$TARGET/$(cts_token_report_rel)"
TOKEN_CALIBRATE_ENTRYPOINT="$TARGET/$(cts_token_calibrate_rel)"

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
    if [ "${migrated:-0}" -gt 0 ]; then
      printf '注意: 旧パスから移した引き継ぎは uninstall.sh では旧位置へ戻らない。必要なら手で戻せ。\n' >&2
    fi
  fi
  exit 1
}
info() { printf '%s\n' "$*"; }
warn() {
  warnings+=("$*")
  printf '  警告: %s\n' "$*"
}

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

cts_place_skill() {
  local name="$1" src="$2" dest="$3" runtime_label="$4" allow_legacy_link="${5:-0}" link recorded
  placed_skill=""
  placed_mode=""

  if [ -z "${CTS_NO_SYMLINK:-}" ] && [ -L "$dest" ] &&
     [ "$(readlink "$dest")" = "$src" ]; then
    placed_skill=1
    placed_mode=link
    return 0
  fi
  if [ -L "$dest" ]; then
    link="$(readlink "$dest")"
    recorded="$(python3 "$CTS_HOME/lib/ledger.py" get-skill "$LEDGER" "$name" | cut -d $'\037' -f1)"
    if [ "$link" != "$recorded" ] &&
       { [ -n "$recorded" ] || [ "$allow_legacy_link" != 1 ] ||
         ! looks_like_our_link "$link" "$name"; }; then
      warn "$runtime_label スキル $name は導入先が張ったリンクなので触らない（$link）"
      return 0
    fi
  elif [ -d "$dest" ]; then
    if [ ! -f "$dest/.claude-token-saver" ]; then
      warn "$runtime_label スキル $name は導入先に既存のディレクトリがあるため触らない（.gitignore にも書かない）"
      return 0
    fi
  elif [ -e "$dest" ]; then
    warn "$runtime_label スキル $name は導入先に既存のファイルがあるため触らない（.gitignore にも書かない）"
    return 0
  fi

  rm -rf "$dest"
  placed_mode=link
  if [ -z "${CTS_NO_SYMLINK:-}" ] && ln -s "$src" "$dest" 2>/dev/null; then
    info "  $runtime_label スキルをリンクした: $name"
  else
    cp -R "$src" "$dest" || die "$runtime_label スキル $name を配置できない"
    printf 'claude-token-saver が配置したコピー。手で編集しない。\n' >"$dest/.claude-token-saver"
    placed_mode=copy
    info "  $runtime_label スキルをコピーで配置した: $name"
  fi
  placed_skill=1
}

cts_destination_is_owned() {
  local src="$1" dest="$2"
  { [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; } ||
    { [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; }
}

# Claude Code スラッシュコマンドは skills と同様にディレクトリパッケージで置く。
# commands/token-saver/ → .claude/commands/token-saver → /token-saver:report など。
looks_like_our_command_link() {
  local link="$1" name="$2" home
  [ "$(basename "$link")" = "$name" ] || return 1
  [ "$(basename "$(dirname "$link")")" = "commands" ] || return 1
  home="$(dirname "$(dirname "$link")")"
  [ -f "$home/install.sh" ]
}

cts_place_command() {
  local name="$1" src="$2" dest="$3" allow_legacy_link="${4:-0}" link recorded
  placed_command=""
  placed_mode=""

  if [ -z "${CTS_NO_SYMLINK:-}" ] && [ -L "$dest" ] &&
     [ "$(readlink "$dest")" = "$src" ]; then
    placed_command=1
    placed_mode=link
    return 0
  fi
  if [ -L "$dest" ]; then
    link="$(readlink "$dest")"
    recorded="$(python3 "$CTS_HOME/lib/ledger.py" get-command "$LEDGER" "$name" | cut -d $'\037' -f1)"
    if [ "$link" != "$recorded" ] &&
       { [ -n "$recorded" ] || [ "$allow_legacy_link" != 1 ] ||
         ! looks_like_our_command_link "$link" "$name"; }; then
      warn "Claude Code コマンド $name は導入先が張ったリンクなので触らない（$link）"
      return 0
    fi
  elif [ -d "$dest" ]; then
    if [ ! -f "$dest/.claude-token-saver" ]; then
      warn "Claude Code コマンド $name は導入先に既存のディレクトリがあるため触らない（.gitignore にも書かない）"
      return 0
    fi
  elif [ -e "$dest" ]; then
    warn "Claude Code コマンド $name は導入先に既存のファイルがあるため触らない（.gitignore にも書かない）"
    return 0
  fi

  rm -rf "$dest"
  placed_mode=link
  if [ -z "${CTS_NO_SYMLINK:-}" ] && ln -s "$src" "$dest" 2>/dev/null; then
    info "  Claude Code コマンドをリンクした: /$name:*"
  else
    cp -R "$src" "$dest" || die "Claude Code コマンド $name を配置できない"
    printf 'claude-token-saver が配置したコピー。手で編集しない。\n' >"$dest/.claude-token-saver" ||
      die "コマンド所有マーカーを書けない"
    placed_mode=copy
    info "  Claude Code コマンドをコピーで配置した: /$name:*"
  fi
  placed_command=1
}

cts_command_destination_is_owned() {
  local src="$1" dest="$2"
  { [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; } ||
    { [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; }
}

cts_reject_managed_symlinks() {
  local path
  for path in \
    "$TARGET/.agents" \
    "$TARGET/.agents/skills" \
    "$TARGET/.claude" \
    "$TARGET/.claude/skills" \
    "$TARGET/.claude/commands" \
    "$TARGET/.codex" \
    "$TARGET/.codex/hooks.json" \
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

# 台帳の Codex managed entry が現在の hooks.json に残っている場合だけ、
# installer が hooks.json を作成した所有権を継承する。ファイル差し替え後に
# 古い作成フラグだけを信じると、uninstall が利用者の空の hooks.json と
# .codex を消してしまうため、台帳と実ファイルを毎回突き合わせる。
cts_codex_hooks_match_ledger() {
  local ledger_path="$1"
  [ -f "$CODEX_HOOKS" ] && [ ! -L "$CODEX_HOOKS" ] || return 1
  [ -f "$ledger_path" ] && [ ! -L "$ledger_path" ] || return 1
  [ -d "$CODEX_DIR" ] && [ ! -L "$CODEX_DIR" ] || return 1
  python3 "$CTS_HOME/lib/settings-hooks.py" validate-codex "$CODEX_HOOKS" \
    --ledger "$ledger_path" >/dev/null 2>&1
}

cts_codex_hooks_is_tracked() {
  local relative_path="${CODEX_HOOKS#"$TARGET/"}"
  git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$TARGET" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1
}

cts_codex_hooks_owned_for_gitignore() {
  local ledger_path="$1"
  [ "$(python3 "$CTS_HOME/lib/ledger.py" get-flag "$ledger_path" codex_hooks_created)" = 1 ] ||
    return 1
  cts_codex_hooks_match_ledger "$ledger_path" || return 1
  cts_codex_hooks_is_tracked && return 1
  return 0
}

command -v python3 >/dev/null 2>&1 ||
  die "python3 が必要である（settings.local.json を壊さずに編集するため）。フック自体は python3 に依存しない。"

if [ "$do_personal" = 1 ]; then
  cts_reject_managed_symlinks
  if [ -e "$CODEX_DIR" ] && [ ! -d "$CODEX_DIR" ]; then
    die ".codex がディレクトリでないため変更しない: $CODEX_DIR"
  fi
  if [ -e "$CODEX_HOOKS" ] && [ ! -f "$CODEX_HOOKS" ]; then
    die ".codex/hooks.json が通常ファイルでないため変更しない: $CODEX_HOOKS"
  fi
  python3 "$CTS_HOME/lib/settings-hooks.py" validate "$CODEX_HOOKS" ||
    die ".codex/hooks.json が妥当なJSONでないため変更しない"
  python3 "$CTS_HOME/lib/ledger.py" check-writable "$LEDGER" ||
    die "台帳に安全に書き込めない"
  python3 "$CTS_HOME/lib/ledger.py" check-writable "$CODEX_HOOKS" ||
    die ".codex/hooks.json に安全に書き込めない"
  python3 "$CTS_HOME/lib/ledger.py" check-writable "$SETTINGS" ||
    die "settings.local.json に安全に書き込めない"
fi
if [ "$do_shared" = 1 ]; then
  python3 "$CTS_HOME/lib/ledger.py" check-writable "$GITIGNORE" ||
    die ".gitignore に安全に書き込めない"
fi

info "claude-token-saver を導入する: $TARGET"

installed_skills=()
claude_installed_skills=()
codex_installed_skills=()
installed_commands=()
claude_installed_commands=()
codex_hook_installed=0
codex_hooks_created=0
codex_dir_created=0
codex_hooks_created_this_run=0
codex_dir_created_this_run=0
if [ "$do_personal" = 1 ]; then
  if [ ! -e "$CODEX_HOOKS" ] && [ ! -L "$CODEX_HOOKS" ]; then
    codex_hooks_created_this_run=1
  fi
  if [ ! -e "$CODEX_DIR" ] && [ ! -L "$CODEX_DIR" ]; then
    codex_dir_created_this_run=1
  fi
fi
gitignore_existed=1
[ -e "$GITIGNORE" ] || [ -L "$GITIGNORE" ] || gitignore_existed=0
legacy_ledger="$TARGET/$(cts_legacy_ledger_rel)"
codex_hooks_ignore=0

if [ "$do_personal" = 1 ]; then

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
# 旧パスの個別エントリを mv で移すときは、シンボリックリンクを実体化せず
# リンク自体を移す。管理対象ディレクトリを包むコンテナシンボリックリンクは
# それより前に拒否しており、移行処理がリンク先を辿って外部を変更することはない。
# リンク先の検証は読み取り時（scripts/handoff-check.sh）が担う。
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
  [ -d "$from" ] && [ ! -L "$from" ] || return 0
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

# 旧台帳が新パスへ移った後で、はじめてCodexの所有フラグを読む。先に新台帳
# （まだ無い）を読んで false を書き戻すと、旧版が作成した hooks.json と
# .codex の所有権を失い、uninstall が空の利用者ファイルを残す契約を壊す。
# 新旧が競合した場合は移行せず、新台帳だけを読む。
if [ "$do_personal" = 1 ]; then
  codex_hooks_created=0
  codex_dir_created=0
  if python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" codex_hooks_created | grep -qx 1; then
    codex_hooks_created=1
  fi
  if python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" codex_dir_created | grep -qx 1; then
    codex_dir_created=1
  fi
  if [ "$codex_hooks_created" = 1 ] && ! cts_codex_hooks_match_ledger "$LEDGER"; then
    # 現在のstrict managed entryと台帳が一致しない場合は、hooks.jsonだけでなく
    # その親ディレクトリの作成所有権も安全側へ失効させる。
    codex_hooks_created=0
    codex_dir_created=0
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

# --- 1c. target-local token-report entrypoint --------------------------------

# shellcheck source=scripts/lib/token-report-entrypoint.sh
. "$CTS_HOME/scripts/lib/token-report-entrypoint.sh" ||
  die "scripts/lib/token-report-entrypoint.sh を読めない（クローンが不完全である）"

cts_install_token_report_entrypoint() {
  local source_launcher="$CTS_HOME/scripts/token-report.sh"
  local recorded_source entry_tmp expected_tmp
  if [ ! -f "$source_launcher" ] || [ ! -f "$CTS_HOME/scripts/measure-token-usage.py" ]; then
    warn "token-report の実体が揃っていないため導入先 entrypoint を設置しない（クローンが不完全である）"
    return 0
  fi

  recorded_source="$(python3 "$CTS_HOME/lib/ledger.py" get-value "$LEDGER" token_report_source)"
  if [ -e "$TOKEN_REPORT_ENTRYPOINT" ] || [ -L "$TOKEN_REPORT_ENTRYPOINT" ]; then
    if [ -z "$recorded_source" ] || [ -L "$TOKEN_REPORT_ENTRYPOINT" ] ||
       [ ! -f "$TOKEN_REPORT_ENTRYPOINT" ]; then
      warn "token-report entrypoint は導入先の既存物なので触らない"
      return 0
    fi
    expected_tmp="$(mktemp "${TMPDIR:-/tmp}/cts-token-report-entrypoint.XXXXXX")" ||
      die "entrypoint の所有権を検証する一時ファイルを作成できない"
    cts_write_token_report_entrypoint "$expected_tmp" "$recorded_source" || {
      rm -f "$expected_tmp"
      die "entrypoint の所有権を検証できない"
    }
    if ! cmp -s "$expected_tmp" "$TOKEN_REPORT_ENTRYPOINT"; then
      rm -f "$expected_tmp"
      warn "token-report entrypoint は導入後に差し替えられているので触らない"
      return 0
    fi
    rm -f "$expected_tmp"
  fi

  entry_tmp="$(mktemp "$TARGET/$(cts_base_rel)/.token-report-entrypoint.XXXXXX")" ||
    die "導入先 entrypoint の一時ファイルを作成できない"
  cts_write_token_report_entrypoint "$entry_tmp" "$source_launcher" || {
    rm -f "$entry_tmp"
    die "導入先 entrypoint を生成できない"
  }
  chmod +x "$entry_tmp" || {
    rm -f "$entry_tmp"
    die "導入先 entrypoint に実行権限を付けられない"
  }
  if [ -f "$TOKEN_REPORT_ENTRYPOINT" ] && cmp -s "$entry_tmp" "$TOKEN_REPORT_ENTRYPOINT"; then
    rm -f "$entry_tmp"
  else
    mv "$entry_tmp" "$TOKEN_REPORT_ENTRYPOINT" || {
      rm -f "$entry_tmp"
      die "導入先 entrypoint を設置できない"
    }
    applied+=("token-report の導入先 entrypoint を設置")
    info "  token-report の入口を設置した: $(cts_token_report_rel)"
  fi
  python3 "$CTS_HOME/lib/ledger.py" set-value "$LEDGER" token_report_source "$source_launcher" ||
    die "token-report entrypoint を台帳へ記録できない"
}

cts_install_token_report_entrypoint

# --- 1d. target-local token-calibrate entrypoint -----------------------------

# shellcheck source=scripts/lib/token-calibrate-entrypoint.sh
. "$CTS_HOME/scripts/lib/token-calibrate-entrypoint.sh" ||
  die "scripts/lib/token-calibrate-entrypoint.sh を読めない（クローンが不完全である）"

cts_install_token_calibrate_entrypoint() {
  local source_launcher="$CTS_HOME/scripts/token-calibrate.sh"
  local recorded_source entry_tmp expected_tmp
  if [ ! -f "$source_launcher" ] ||
     [ ! -f "$CTS_HOME/scripts/apply-token-calibration.py" ] ||
     [ ! -f "$CTS_HOME/scripts/measure-token-usage.py" ]; then
    warn "token-calibrate の実体が揃っていないため導入先 entrypoint を設置しない（クローンが不完全である）"
    return 0
  fi

  recorded_source="$(python3 "$CTS_HOME/lib/ledger.py" get-value "$LEDGER" token_calibrate_source)"
  if [ -e "$TOKEN_CALIBRATE_ENTRYPOINT" ] || [ -L "$TOKEN_CALIBRATE_ENTRYPOINT" ]; then
    if [ -z "$recorded_source" ] || [ -L "$TOKEN_CALIBRATE_ENTRYPOINT" ] ||
       [ ! -f "$TOKEN_CALIBRATE_ENTRYPOINT" ]; then
      warn "token-calibrate entrypoint は導入先の既存物なので触らない"
      return 0
    fi
    expected_tmp="$(mktemp "${TMPDIR:-/tmp}/cts-token-calibrate-entrypoint.XXXXXX")" ||
      die "token-calibrate entrypoint の所有権を検証する一時ファイルを作成できない"
    cts_write_token_calibrate_entrypoint "$expected_tmp" "$recorded_source" || {
      rm -f "$expected_tmp"
      die "token-calibrate entrypoint の所有権を検証できない"
    }
    if ! cmp -s "$expected_tmp" "$TOKEN_CALIBRATE_ENTRYPOINT"; then
      rm -f "$expected_tmp"
      warn "token-calibrate entrypoint は導入後に差し替えられているので触らない"
      return 0
    fi
    rm -f "$expected_tmp"
  fi

  entry_tmp="$(mktemp "$TARGET/$(cts_base_rel)/.token-calibrate-entrypoint.XXXXXX")" ||
    die "導入先 token-calibrate entrypoint の一時ファイルを作成できない"
  cts_write_token_calibrate_entrypoint "$entry_tmp" "$source_launcher" || {
    rm -f "$entry_tmp"
    die "導入先 token-calibrate entrypoint を生成できない"
  }
  chmod +x "$entry_tmp" || {
    rm -f "$entry_tmp"
    die "導入先 token-calibrate entrypoint に実行権限を付けられない"
  }
  if [ -f "$TOKEN_CALIBRATE_ENTRYPOINT" ] &&
     cmp -s "$entry_tmp" "$TOKEN_CALIBRATE_ENTRYPOINT"; then
    rm -f "$entry_tmp"
  else
    mv "$entry_tmp" "$TOKEN_CALIBRATE_ENTRYPOINT" || {
      rm -f "$entry_tmp"
      die "導入先 token-calibrate entrypoint を設置できない"
    }
    applied+=("token-calibrate の導入先 entrypoint を設置")
    info "  token-calibrate の入口を設置した: $(cts_token_calibrate_rel)"
  fi
  python3 "$CTS_HOME/lib/ledger.py" set-value "$LEDGER" token_calibrate_source "$source_launcher" ||
    die "token-calibrate entrypoint を台帳へ記録できない"
}

cts_install_token_calibrate_entrypoint

# applied への記録は各ファイル・台帳を移した直後に済んでいる（die 時に漏れ
# させないため）。ここでは締めくくりとして利用者向けに件数を要約するだけで、
# applied への追記はしない。移した件数だけでなく、衝突で旧側に残した件数も
# 伝える。migrate_conflicts を数えるだけで語らないと、利用者は何件が衝突した
# のか警告メッセージを1つずつ数えるしかなくなる。
if [ "$migrated" -gt 0 ] || [ "$migrate_conflicts" -gt 0 ]; then
  info "旧パス（.claude 配下）からの移行: $migrated 件を移行、$migrate_conflicts 件は衝突のため旧側に残した"
fi

# --- 2. フックの登録 ---------------------------------------------------------

# 実体のあるスクリプトだけを登録する。存在しないコマンドを登録すると、
# 導入先のセッションでフックが毎回失敗する。
hook_specs=()
hook_matchers=()
if [ -f "$CTS_HOME/scripts/handoff-check.sh" ]; then
  hook_specs+=("SessionStart:$CTS_HOME/scripts/handoff-check.sh")
  hook_matchers+=("--matcher" "SessionStart=startup|clear")
else
  warn "scripts/handoff-check.sh が無いため SessionStart フックを登録しない（クローンが不完全である）"
fi
if [ -f "$CTS_HOME/scripts/suggest-session-cut.sh" ]; then
  hook_specs+=("Stop:$CTS_HOME/scripts/suggest-session-cut.sh")
else
  warn "クローンが不完全なため Stop フックを登録しない（scripts/suggest-session-cut.sh が無い）"
fi

if [ "${#hook_specs[@]}" -gt 0 ]; then
  # settings.local.json は通常 git 管理外の個人設定である。git から復元でき
  # ないので、最初の書き換え前に控えを取る。既にあれば上書きしない（原状の
  # 控えを、再実行で自分の書いた内容へ塗り替えては意味がない）。
  # 既にあれば上書きしないのは意図である。控えの値打ちは「導入より前の内容」で
  # あることに尽きる。再実行で更新すると、自分が書いた内容へ塗り替わって
  # 復旧手段が失われる。既存の控えが壊れた JSON の写しであっても、それが
  # 原状であるから直すのは原本のほうであり、控えを作り直す話ではない。
  settings_created_this_run=0
  if python3 "$CTS_HOME/lib/ledger.py" get-flag "$LEDGER" settings_created | grep -qx 1; then
    settings_created=1
  else
    settings_created=0
  fi
  if [ ! -e "$SETTINGS" ] && [ ! -L "$SETTINGS" ]; then
    settings_created_this_run=1
  fi
  if [ "$settings_created_this_run" = 0 ] &&
     [ "$settings_created" = 0 ] && [ -f "$SETTINGS" ] && [ ! -e "$BACKUP" ]; then
    cp -p "$SETTINGS" "$BACKUP" || die "settings.local.json の控えを作れない"
    backup_path="$BACKUP"
    # 控えは settings.local.json の書き換えより前に作られるため、この後で
    # die しても残る。applied に載せなければ、利用者は残ったことを知らない。
    applied+=("settings.local.json の控えを作成（導入前の内容）: $BACKUP")
  fi

  python3 "$CTS_HOME/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$LEDGER" "${hook_matchers[@]}" "${hook_specs[@]}"
  settings_status=$?
  case "$settings_status" in
    0) ;;
    2) warnings+=("settings.local.json に台帳無しの推測候補があるため、候補を削除せずフックを登録した") ;;
    *) die "settings.local.json または台帳を更新できない" ;;
  esac
  if [ "$settings_created_this_run" = 1 ]; then
    python3 "$CTS_HOME/lib/ledger.py" set-flag "$LEDGER" settings_created 1 ||
      die "台帳を更新できない"
    settings_created=1
  fi
  applied+=("settings.local.json へフックを登録")
fi

if [ -f "$CTS_HOME/scripts/handoff-check.sh" ]; then
  python3 "$CTS_HOME/lib/settings-hooks.py" install "$CODEX_HOOKS" \
    --ledger "$LEDGER" \
    --ledger-key codex_hooks \
    --matcher "SessionStart=startup|clear" \
    --additional-context-limit "SessionStart=10000" \
    "SessionStart:$CTS_HOME/scripts/handoff-check.sh"
  codex_status=$?
  case "$codex_status" in
    0) ;;
    2) warnings+=(".codex/hooks.json に台帳無しの推測候補があるため、候補を削除せずフックを登録した") ;;
    *) die ".codex/hooks.json またはCodex用台帳を更新できない" ;;
  esac
  if [ "$codex_hooks_created_this_run" = 1 ]; then
    codex_hooks_created=1
  fi
  if [ "$codex_dir_created_this_run" = 1 ]; then
    codex_dir_created=1
  fi
  python3 "$CTS_HOME/lib/ledger.py" set-flag "$LEDGER" codex_hooks_created "$codex_hooks_created" ||
    die "Codex hooks.jsonの所有フラグを台帳へ記録できない"
  python3 "$CTS_HOME/lib/ledger.py" set-flag "$LEDGER" codex_dir_created "$codex_dir_created" ||
    die ".codexの所有フラグを台帳へ記録できない"
  codex_hook_installed=1
  if cts_codex_hooks_owned_for_gitignore "$LEDGER"; then
    codex_hooks_ignore=1
  fi
  applied+=(".codex/hooks.json へCodex SessionStartフックを登録")
  info "  Codex の project hook を登録した。Codex の /hooks で定義を確認し、trust せよ。"
fi

# --- 3. スキルのリンク -------------------------------------------------------

# 実体はクローン先に1つだけ置く。複数プロジェクトへ導入しても更新は git pull 1回で全体へ届く。
mkdir -p "$TARGET/.claude/skills" || die "skills ディレクトリを作成できない"

# 実際に設置したスキルだけを .gitignore へ書くため、名前を集める。
found_skills=0

for skill_dir in "$CTS_HOME"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  found_skills=$((found_skills + 1))
  name="$(basename "$skill_dir")"
  src="${skill_dir%/}"

  installed_any=""
  ledger_mode=""
  cts_place_skill "$name" "$src" "$TARGET/.claude/skills/$name" "Claude Code" 1
  if [ -n "$placed_skill" ]; then
    claude_installed_skills+=("$name")
    installed_any=1
    ledger_mode="$placed_mode"
  fi

  if [ -f "$src/agents/openai.yaml" ]; then
    mkdir -p "$TARGET/.agents/skills" || die "Codex skills ディレクトリを作成できない"
    cts_place_skill "$name" "$src" "$TARGET/.agents/skills/$name" "Codex" 0
    if [ -n "$placed_skill" ]; then
      codex_installed_skills+=("$name")
      installed_any=1
      [ -n "$ledger_mode" ] || ledger_mode="$placed_mode"
    fi
  fi

  if [ -n "$installed_any" ]; then
    python3 "$CTS_HOME/lib/ledger.py" add-skill "$LEDGER" "$name" "$src" "$ledger_mode" ||
      die "台帳を更新できない"
    installed_skills+=("$name")
    applied+=("スキル $name を設置")
  fi
done

[ "$found_skills" -gt 0 ] ||
  warn "skills/ にスキルが1つも無いため何も設置していない（クローンが不完全である）"

# --- 3b. Claude Code スラッシュコマンド --------------------------------------

mkdir -p "$TARGET/.claude/commands" || die "commands ディレクトリを作成できない"

found_commands=0
for command_dir in "$CTS_HOME"/commands/*/; do
  [ -d "$command_dir" ] || continue
  name="$(basename "$command_dir")"
  case "$name" in
    "" | . | .. | */*)
      warn "コマンド名が不正なので設置しない: $name"
      continue
      ;;
  esac
  if ! find "$command_dir" -maxdepth 1 -type f -name '*.md' -print -quit 2>/dev/null | grep -q .; then
    continue
  fi
  found_commands=$((found_commands + 1))
  src="$(cd "$command_dir" && pwd)"
  dest="$TARGET/.claude/commands/$name"
  cts_place_command "$name" "$src" "$dest" 1
  if [ -n "$placed_command" ]; then
    python3 "$CTS_HOME/lib/ledger.py" add-command "$LEDGER" "$name" "$src" "$placed_mode" ||
      die "台帳を更新できない"
    installed_commands+=("$name")
    claude_installed_commands+=("$name")
    applied+=("コマンドパッケージ /$name:* を設置")
  fi
done

[ "$found_commands" -gt 0 ] ||
  warn "commands/ にコマンドが1つも無いため何も設置していない（クローンが不完全である）"



fi

if [ "$do_shared" = 1 ] && [ "$do_personal" = 0 ]; then
  shared_ledger="$TARGET/$(cts_ledger_rel)"
  if ! python3 "$CTS_HOME/lib/ledger.py" has-record "$shared_ledger" skills &&
     python3 "$CTS_HOME/lib/ledger.py" has-record "$legacy_ledger" skills; then
    shared_ledger="$legacy_ledger"
  fi

  # 共有設定では個人領域を推測しない。台帳に実際に記録されたスキル名だけを
  # 読み、台帳が無ければ状態ディレクトリの除外だけを書く。
  while IFS=$'\037' read -r name src _mode; do
    case "$name" in
      "" | . | .. | */*)
        [ -z "$name" ] || warn "台帳のスキル名が不正なので .gitignore に書かない: $name"
        ;;
      *)
        installed_skills+=("$name")
        if cts_destination_is_owned "$src" "$TARGET/.claude/skills/$name"; then
          claude_installed_skills+=("$name")
        fi
        if [ -f "$src/agents/openai.yaml" ] &&
           cts_destination_is_owned "$src" "$TARGET/.agents/skills/$name"; then
          codex_installed_skills+=("$name")
        fi
        ;;
    esac
  done < <(python3 "$CTS_HOME/lib/ledger.py" list-skills "$shared_ledger")

  while IFS=$'\037' read -r name src _mode; do
    case "$name" in
      "" | . | .. | */*)
        [ -z "$name" ] || warn "台帳のコマンド名が不正なので .gitignore に書かない: $name"
        ;;
      *)
        installed_commands+=("$name")
        if cts_command_destination_is_owned "$src" "$TARGET/.claude/commands/$name"; then
          claude_installed_commands+=("$name")
        fi
        ;;
    esac
  done < <(python3 "$CTS_HOME/lib/ledger.py" list-commands "$shared_ledger")

  shared_codex_ledger="$TARGET/$(cts_ledger_rel)"
  if ! python3 "$CTS_HOME/lib/ledger.py" has-record "$shared_codex_ledger" codex_hooks &&
     python3 "$CTS_HOME/lib/ledger.py" has-record "$legacy_ledger" codex_hooks; then
    shared_codex_ledger="$legacy_ledger"
  fi
  if cts_codex_hooks_owned_for_gitignore "$shared_codex_ledger"; then
    codex_hooks_ignore=1
  fi
fi

# --- 4. .gitignore -----------------------------------------------------------
if [ "$do_shared" = 1 ]; then

# 引き継ぎと状態ファイルは利用実績であり、既定では版管理しない。
# スキルのリンクは絶対パスを指す環境依存の産物であり、版管理へ入れると
# 他の開発者のクローンで壊れたリンクになる。
#
# ブロックは毎回作り直す。存在確認だけで済ませると、スキルが増えたときに
# 無視行が追加されず、リンクが版管理対象として現れる。
# 無視行を書くのは実際に設置したスキル・コマンドだけに限る。触らなかったものを
# 無視すると、その版管理を静かに壊す。
{
  printf '%s/\n' "$(cts_base_rel)"
  if [ "$codex_hooks_ignore" = 1 ]; then
    printf '.codex/hooks.json\n'
  fi
  for name in ${claude_installed_skills[@]+"${claude_installed_skills[@]}"}; do
    printf '.claude/skills/%s\n' "$name"
  done
  for name in ${codex_installed_skills[@]+"${codex_installed_skills[@]}"}; do
    printf '.agents/skills/%s\n' "$name"
  done
  for name in ${claude_installed_commands[@]+"${claude_installed_commands[@]}"}; do
    printf '.claude/commands/%s\n' "$name"
  done
} | python3 "$CTS_HOME/lib/gitignore-block.py" apply "$GITIGNORE"
gitignore_status=$?
case "$gitignore_status" in
  # applied は失敗時の唯一の説明手段である。実際に書いたときだけ積む。
  0) applied+=(".gitignore を更新") ;;
  3) ;;
  2) warnings+=(".gitignore のブロックが不正または改行形式が混在しているため更新していない") ;;
  *) die ".gitignore を更新できない" ;;
esac

# 自分で作った .gitignore だけを、取り外しのときに消してよい。
if [ "$gitignore_existed" = 0 ] && [ -e "$GITIGNORE" ]; then
  if [ "$do_personal" = 1 ]; then
    python3 "$CTS_HOME/lib/ledger.py" set-flag "$LEDGER" gitignore_created 1 ||
      die "台帳を更新できない"
  fi
fi
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
  if [ "$do_shared" = 1 ] && [ "$do_personal" = 0 ]; then
    info "完了。共有設定（.gitignore）を更新した。"
  elif [ "$do_personal" = 1 ] && [ "$do_shared" = 0 ]; then
    info "完了。個人設定を更新した。.gitignore は変更していない。共有設定も更新する場合は install.sh --shared を実行せよ。"
  else
    info "完了。新しいセッションを開始すると引き継ぎフックが有効になる。"
  fi
fi
exit 0
