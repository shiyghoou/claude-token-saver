#!/usr/bin/env bash

set -uo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ENGINE="$SOURCE_DIR/measure-token-usage.py"
# shellcheck source=scripts/lib/paths.sh
. "$SOURCE_DIR/lib/paths.sh" || exit 1

find_target_root() {
  local current parent git_root
  if [ -n "${CTS_TOKEN_REPORT_TARGET_ROOT:-}" ]; then
    (cd -- "$CTS_TOKEN_REPORT_TARGET_ROOT" 2>/dev/null && pwd -P)
    return $?
  fi
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
    if [ -n "$git_root" ]; then
      (cd -- "$git_root" 2>/dev/null && pwd -P)
      return $?
    fi
  fi
  current="$(pwd -P)" || return 1
  while :; do
    if [ -e "$current/.git" ] || [ -d "$current/.claude" ]; then
      printf '%s\n' "$current"
      return 0
    fi
    parent="$(dirname "$current")"
    if [ "$parent" = "$current" ]; then
      printf '%s\n' "$(pwd -P)"
      return 0
    fi
    current="$parent"
  done
}

REPO_ROOT="$(find_target_root)" || {
  printf '計測対象のリポジトリルートを解決できません\n' >&2
  exit 1
}

explicit_out=0
expect_out_value=0
out_path=""
tmp_out=""
report_path=""
default_output=0
placement_tmp=""
report_dir=""
report_dir_created=0
calibrate_requested=0
snapshot_path=""
snapshot_identity=""
snapshot_had_regular=0

cleanup() {
  rm -f "$marker"
  if [ -n "$tmp_out" ]; then
    rm -f "$tmp_out"
  fi
  if [ -n "$placement_tmp" ]; then
    rm -f "$placement_tmp"
  fi
  if [ -n "$snapshot_identity" ]; then
    rm -f "$snapshot_identity"
  fi
  if [ "$report_dir_created" -eq 1 ] && [ -n "$report_dir" ]; then
    rmdir "$report_dir" 2>/dev/null || true
    rmdir "$(dirname "$report_dir")" 2>/dev/null || true
  fi
}

for arg in "$@"; do
  if [ "$expect_out_value" -eq 1 ]; then
    out_path="$arg"
    expect_out_value=0
    continue
  fi
  case "$arg" in
    --calibrate)
      calibrate_requested=1
      ;;
    --out)
      explicit_out=1
      expect_out_value=1
      ;;
    --out=*)
      explicit_out=1
      out_path="${arg#--out=}"
      ;;
  esac
done

if [ "$explicit_out" -eq 0 ]; then
  default_output=1
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 が見つかりません: %s を実行できません\n' "$ENGINE" >&2
  exit 1
fi

marker="$(mktemp "${TMPDIR:-/tmp}/cts-token-report.XXXXXX")" || {
  printf '更新検査用の一時ファイルを作成できません\n' >&2
  exit 1
}
trap cleanup EXIT

if [ "$default_output" -eq 1 ]; then
  tmp_out="$(mktemp "${TMPDIR:-/tmp}/cts-token-report-output.XXXXXX")" || {
    printf '一時レポートを作成できません\n' >&2
    exit 1
  }
  report_path="$tmp_out"
  set -- "$@" --out "$report_path"
else
  report_path="$out_path"
fi

if [ "$calibrate_requested" -eq 1 ]; then
  snapshot_root="$REPO_ROOT/$(cts_base_rel)"
  snapshot_dir="$snapshot_root/calibration"
  snapshot_path="$snapshot_dir/latest.json"
  if [ -L "$snapshot_root" ] || [ -L "$snapshot_dir" ] || [ -L "$snapshot_path" ]; then
    printf 'キャリブレーション snapshot の保存先が symlink です: %s\n' "$snapshot_path" >&2
    exit 1
  fi
  if [ -f "$snapshot_path" ]; then
    snapshot_identity="$(mktemp "$snapshot_dir/.token-report-snapshot.XXXXXX")" || {
      printf '既存 snapshot の更新識別子を作成できません: %s\n' "$snapshot_dir" >&2
      exit 1
    }
    rm -f "$snapshot_identity"
    ln "$snapshot_path" "$snapshot_identity" || {
      printf '既存 snapshot の更新識別子を作成できません: %s\n' "$snapshot_path" >&2
      exit 1
    }
    snapshot_had_regular=1
  fi
fi

(cd "$REPO_ROOT" && python3 -B "$ENGINE" "$@" >/dev/null)
status=$?
if [ "$status" -ne 0 ]; then
  exit "$status"
fi

if [ "$calibrate_requested" -eq 1 ]; then
  if [ -L "$snapshot_root" ] || [ -L "$snapshot_dir" ] || [ -L "$snapshot_path" ] || \
    [ ! -f "$snapshot_path" ] || [ ! -s "$snapshot_path" ]; then
    printf 'キャリブレーション snapshot が通常の非空ファイルではありません: %s\n' \
      "$snapshot_path" >&2
    exit 1
  fi
  if [ "$snapshot_had_regular" -eq 1 ] && [ "$snapshot_path" -ef "$snapshot_identity" ]; then
    printf 'キャリブレーション snapshot がこの実行で置き換えられていません: %s\n' \
      "$snapshot_path" >&2
    exit 1
  fi
  if [ "$snapshot_had_regular" -eq 0 ] && [ ! "$snapshot_path" -nt "$marker" ]; then
    printf 'キャリブレーション snapshot がこの実行で更新されていません: %s\n' \
      "$snapshot_path" >&2
    exit 1
  fi
fi

if [ -z "$report_path" ]; then
  printf 'レポート出力先を特定できませんでした\n' >&2
  exit 1
fi

if [ ! -e "$report_path" ] && [ ! -L "$report_path" ]; then
  printf 'レポートが作成されていません: %s\n' "$report_path" >&2
  exit 1
fi

if [ ! -s "$report_path" ]; then
  printf 'レポートが空です: %s\n' "$report_path" >&2
  exit 1
fi

# 既定出力は launcher がこの実行専用に作った空の mktemp へ書かせているため、
# 非空・形式検査だけで今回の成果物だと確定できる。秒単位 mtime の環境で -nt を
# 使うと、marker と engine 出力が同じ秒になり正常な成果物を誤拒否する。
# 利用者が指定した既存 --out だけは、前回成果物の誤認を防ぐため freshness も見る。
if [ "$default_output" -eq 0 ] && [ ! "$report_path" -nt "$marker" ]; then
  printf 'レポートがこの実行で更新されていません: %s\n' "$report_path" >&2
  exit 1
fi

head_lines="$(sed -n '1,40p' "$report_path")"
case "$head_lines" in
  *"## 計測条件"*) ;;
  *)
    printf 'レポート先頭に計測条件セクションがありません: %s\n' "$report_path" >&2
    exit 1
    ;;
esac

if [ "$default_output" -eq 1 ]; then
  report_dir="$REPO_ROOT/$(cts_base_rel)/token-reports"
  if [ ! -d "$report_dir" ]; then
    report_dir_created=1
  fi
  mkdir -p "$report_dir" || {
    printf 'レポート出力先を作成できません: %s\n' "$report_dir" >&2
    exit 1
  }
  placement_tmp="$(mktemp "$report_dir/.token-report.XXXXXX")" || {
    printf '配置用の一時ファイルを作成できません: %s\n' "$report_dir" >&2
    exit 1
  }
  mv "$report_path" "$placement_tmp" || {
    printf '検証済みレポートを配置用一時ファイルへ移動できません\n' >&2
    exit 1
  }
  tmp_out=""
  report_path="$placement_tmp"
  stamp="$(date +%Y%m%d-%H%M%S)" || {
    printf 'レポートの日時を取得できません\n' >&2
    exit 1
  }
  out_path="$report_dir/$stamp.md"
  suffix=2
  while :; do
    if ln "$placement_tmp" "$out_path" 2>/dev/null; then
      break
    fi
    if [ -e "$out_path" ] || [ -L "$out_path" ]; then
      out_path="$report_dir/$stamp-$suffix.md"
      suffix=$((suffix + 1))
      continue
    fi
    printf '検証済みレポートを原子的に配置できません: %s\n' "$out_path" >&2
    exit 1
  done
  rm -f "$placement_tmp"
  placement_tmp=""
  report_path="$out_path"
fi

printf '書き出しました: %s\n' "$out_path"
