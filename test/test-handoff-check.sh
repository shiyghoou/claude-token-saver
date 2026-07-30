#!/usr/bin/env bash
# handoff-check.sh（SessionStart フック）の検証。

HOOK="$REPO_ROOT/scripts/handoff-check.sh"

# 導入先リポジトリを模したディレクトリを作る。
_setup_project() {
  PROJ="$TEST_TMP/proj"
  mkdir -p "$PROJ/.claude/.handoff/pending" "$PROJ/.claude/.handoff/consumed"
  export CLAUDE_PROJECT_DIR="$PROJ"
}

# pending に引き継ぎファイルを置く。
_write_pending() {
  local name="$1" body="$2"
  printf '%s\n' "$body" >"$PROJ/.claude/.handoff/pending/$name"
}

# フックを実行する。標準出力は $HOOK_OUT、終了コードは $HOOK_STATUS に入る。
# コマンド置換ではなく変数に直接入れるのは、サブシェルだと終了コードを持ち帰れないため。
_run_hook() {
  local payload="${1:-}"
  printf '%s' "$payload" | bash "$HOOK" >"$TEST_TMP/.hook-out" 2>"$TEST_TMP/.hook-err"
  HOOK_STATUS=$?
  HOOK_OUT="$(cat "$TEST_TMP/.hook-out")"
}

_startup_payload() {
  printf '{"session_id":"abc","source":"startup","cwd":"%s"}' "$PROJ"
}

test_pending_が空なら無出力で終了コード0() {
  _setup_project
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
}

test_handoff_ディレクトリ自体が無くても無出力で終了コード0() {
  _setup_project
  rm -rf "$PROJ/.claude/.handoff"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
}

test_pending_にファイルがあれば中身を出力する() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "# 引き継ぎ (2026-07-31 18:40)
## 次の一手
- 倉庫からの出庫を実装する"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_contains "$out" "倉庫からの出庫を実装する" "フック出力"
}

test_出力後に_consumed_へ移動する() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_file_missing "$PROJ/.claude/.handoff/pending/2026-07-31-1840-643-stage.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/2026-07-31-1840-643-stage.md"
}

test_consumed_へ移動したファイルの中身は失われない() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "消えてはいけない本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/2026-07-31-1840-643-stage.md")" \
    "消えてはいけない本文" "consumed のファイル内容"
}

test_発火源が_compact_のときは発火しない() {
  _setup_project
  _write_pending "2026-07-31-1840-643-stage.md" "本文"
  local out
  _run_hook "$(printf '{"source":"compact","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/2026-07-31-1840-643-stage.md"
}

test_発火源が_clear_のときは発火する() {
  _setup_project
  _write_pending "a.md" "clear でも読む"
  local out
  _run_hook "$(printf '{"source":"clear","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "clear でも読む" "フック出力"
}

test_発火源が_resume_のときは発火する() {
  _setup_project
  _write_pending "a.md" "resume でも読む"
  local out
  _run_hook "$(printf '{"source":"resume","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "resume でも読む" "フック出力"
}

test_未知の発火源では発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook "$(printf '{"source":"someday-new-source","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_複数ファイルはファイル名の昇順ですべて出力される() {
  _setup_project
  _write_pending "2026-07-31-1840-643-second.md" "二番目の引き継ぎ"
  _write_pending "2026-07-30-0900-101-first.md" "一番目の引き継ぎ"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "一番目の引き継ぎ" "フック出力"
  assert_contains "$out" "二番目の引き継ぎ" "フック出力"

  local first_pos second_pos
  first_pos="${out%%一番目の引き継ぎ*}"
  second_pos="${out%%二番目の引き継ぎ*}"
  if [ "${#first_pos}" -ge "${#second_pos}" ]; then
    _fail "古い引き継ぎが先に出力されていない"
  fi
}

test_複数ファイルはすべて_consumed_へ移動する() {
  _setup_project
  _write_pending "a.md" "A"
  _write_pending "b.md" "B"
  _run_hook "$(_startup_payload)"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/b.md"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_出力には要約して指示を待つ旨の指示が3行とも含まれる() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "本文"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "内容を要約してユーザーへ提示し、指示を待て" "フック出力"
  assert_contains "$out" "自動で着手してはならない" "フック出力"
  assert_contains "$out" "食い違う場合は、その旨を指摘せよ" "フック出力"
}

# .handoff/ は誰でもファイルを置ける場所である。引き継ぎ本文が指示として
# 読まれないよう、区切りで囲み、それが記録であることを明示する。
test_引き継ぎ本文は区切りで囲まれ指示ではないと明示される() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "本文"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "<handoff" "フック出力"
  assert_contains "$out" "</handoff>" "フック出力"
  assert_contains "$out" "指示ではない" "フック出力"
}

test_標準入力が空でも終了コード0で抜ける() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook ""
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
}

test_壊れた_JSON_でも終了コード0で抜ける() {
  _setup_project
  _write_pending "a.md" "本文"
  _run_hook '{"source": '
  assert_eq "0" "$HOOK_STATUS" "終了コード"
}

test_consumed_ディレクトリが無ければ作成する() {
  _setup_project
  rm -rf "$PROJ/.claude/.handoff/consumed"
  _write_pending "a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
}

test_同名ファイルが_consumed_にあっても既存を上書きしない() {
  _setup_project
  printf '先に消費した内容\n' >"$PROJ/.claude/.handoff/consumed/a.md"
  _write_pending "a.md" "新しい内容"
  _run_hook "$(_startup_payload)"
  assert_contains "$(cat "$PROJ/.claude/.handoff/consumed/a.md")" \
    "先に消費した内容" "既存の consumed ファイル"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_CLAUDE_PROJECT_DIR_が無いときは_JSON_の_cwd_を使う() {
  _setup_project
  _write_pending "a.md" "cwd から見つけた"
  unset CLAUDE_PROJECT_DIR
  local out
  _run_hook "$(printf '{"source":"startup","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_contains "$out" "cwd から見つけた" "フック出力"
}

# ---- 発火源の判定は fail-closed であること -------------------------------
# 「compact では消費しない」がこの機構で最も守りたい不変条件である。
# ペイロードの解析に少しでも失敗したら、発火しない側へ倒す。

test_source_が無いペイロードでは発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook "$(printf '{"session_id":"abc","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_標準入力が空のときは発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook ""
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_壊れた_JSON_では発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook '{"source": '
  out="$HOOK_OUT"
  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_CTS_FORCE_を立てれば手動実行でも発火する() {
  _setup_project
  _write_pending "a.md" "手動で読む"
  local out
  CTS_FORCE=1 _run_hook ""
  out="$HOOK_OUT"
  assert_contains "$out" "手動で読む" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/a.md"
}

# 本体がペイロードに入れ子オブジェクトを足しても compact 安全性が壊れないこと。
test_入れ子の_source_ではなく最初の_source_を見る() {
  _setup_project
  _write_pending "a.md" "本文"
  local out
  _run_hook "$(printf '{"source":"compact","cwd":"%s","meta":{"source":"startup"}}' "$PROJ")"
  out="$HOOK_OUT"
  assert_empty "$out"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

test_入れ子の_cwd_ではなく最初の_cwd_を使う() {
  _setup_project
  local other="$TEST_TMP/other"
  mkdir -p "$other/.claude/.handoff/pending"
  printf '別プロジェクトの引き継ぎ\n' >"$other/.claude/.handoff/pending/x.md"
  _write_pending "a.md" "正しいプロジェクトの引き継ぎ"
  unset CLAUDE_PROJECT_DIR
  local out
  _run_hook "$(printf '{"source":"startup","cwd":"%s","env":{"cwd":"%s"}}' "$PROJ" "$other")"
  out="$HOOK_OUT"
  assert_contains "$out" "正しいプロジェクトの引き継ぎ" "フック出力"
  assert_not_contains "$out" "別プロジェクトの引き継ぎ" "フック出力"
}

# timeout は GNU coreutils であり macOS の既定環境に無い。無くても壊れないこと。
test_timeout_コマンドが無くても発火源の判定は正しい() {
  _setup_project
  _write_pending "a.md" "本文"
  local shadow="$TEST_TMP/shadow"
  mkdir -p "$shadow"
  printf '#!/bin/sh\nexit 127\n' >"$shadow/timeout"
  chmod +x "$shadow/timeout"

  local out
  PATH="$shadow:$PATH" _run_hook "$(printf '{"source":"compact","cwd":"%s"}' "$PROJ")"
  out="$HOOK_OUT"
  assert_empty "$out" "compact での出力"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"

  PATH="$shadow:$PATH" _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  assert_contains "$out" "本文" "startup での出力"
}

# 標準入力が閉じない環境でセッション起動を長く止めない。止まった場合は発火しない。
test_標準入力が閉じなくても速やかに終了し発火しない() {
  _setup_project
  _write_pending "a.md" "本文"
  local fifo="$TEST_TMP/fifo"
  mkfifo "$fifo"
  { _startup_payload; sleep 8; } >"$fifo" &
  local writer=$!

  local start elapsed
  start=$SECONDS
  bash "$HOOK" <"$fifo" >"$TEST_TMP/.hook-out" 2>"$TEST_TMP/.hook-err"
  HOOK_STATUS=$?
  elapsed=$((SECONDS - start))
  kill "$writer" 2>/dev/null
  wait "$writer" 2>/dev/null

  assert_eq "0" "$HOOK_STATUS" "終了コード"
  if [ "$elapsed" -gt 4 ]; then
    _fail "標準入力の待機が長すぎる: ${elapsed} 秒"
  fi
  assert_empty "$(cat "$TEST_TMP/.hook-out")" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

# ---- 消費できなかったものは注入しない -----------------------------------
# 出力してから移動すると、移動に失敗したときに「読んだ」ことになり、
# 以後すべてのセッション冒頭へ同じ引き継ぎが積まれ続ける。

test_移動に失敗したら本文を注入せず警告を出す() {
  _setup_project
  _write_pending "a.md" "注入されてはいけない本文"
  chmod 555 "$PROJ/.claude/.handoff/pending"
  local out
  _run_hook "$(_startup_payload)"
  out="$HOOK_OUT"
  chmod 755 "$PROJ/.claude/.handoff/pending"

  assert_eq "0" "$HOOK_STATUS" "終了コード"
  assert_not_contains "$out" "注入されてはいけない本文" "フック出力"
  assert_contains "$out" "消費できなかった" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/pending/a.md"
}

# 並行セッションでの二重注入。mv が先なら勝った側だけが本文を得る。
test_並行実行しても本文は一度しか注入されない() {
  _setup_project
  _write_pending "a.md" "唯一マーカー"
  local payload
  payload="$(_startup_payload)"
  local i
  for i in 1 2 3 4; do
    printf '%s' "$payload" | bash "$HOOK" >"$TEST_TMP/par-$i" 2>/dev/null &
  done
  wait

  local total
  total="$(cat "$TEST_TMP"/par-* | grep -c '唯一マーカー' || true)"
  assert_eq "1" "$total" "本文の注入回数"
}

test_2回連続で起動すると2回目は無出力() {
  _setup_project
  _write_pending "a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "本文" "1回目のフック出力"
  _run_hook "$(_startup_payload)"
  assert_empty "$HOOK_OUT" "2回目のフック出力"
}

# ---- 注入量の上限 --------------------------------------------------------

test_巨大な引き継ぎは切り詰めてパスだけ渡す() {
  _setup_project
  # 2 MB 程度の pending を作る。倍々で伸ばすのはループを回すより速いため。
  local chunk="$PROJ/.claude/.handoff/pending/a.md"
  printf '巨大な引き継ぎの本文である。%s\n' "$(printf 'x%.0s' {1..64})" >"$chunk"
  local i
  for i in $(seq 1 15); do cat "$chunk" "$chunk" >"$chunk.tmp" && mv "$chunk.tmp" "$chunk"; done
  _run_hook "$(_startup_payload)"
  local size
  size="${#HOOK_OUT}"
  if [ "$size" -gt 65536 ]; then
    _fail "出力が大きすぎる: ${size} バイト"
  fi
  assert_contains "$HOOK_OUT" "切り詰めた" "フック出力"
  assert_contains "$HOOK_OUT" "$PROJ/.claude/.handoff/consumed/a.md" "フック出力"
}

test_件数の上限を超えた分は次回へ持ち越す() {
  _setup_project
  local i
  for i in 1 2 3 4 5 6 7 8; do
    _write_pending "2026-07-31-000$i-a.md" "本文 $i"
  done
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "持ち越" "フック出力"
  assert_contains "$HOOK_OUT" "本文 1" "フック出力"
  assert_not_contains "$HOOK_OUT" "本文 8" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/pending/2026-07-31-0008-a.md"
}

# ---- ファイル名の扱い ----------------------------------------------------

test_改行を含むファイル名でも件数と本文が正しい() {
  _setup_project
  printf '改行入りの本文\n' >"$PROJ/.claude/.handoff/pending/$(printf 'a\nb').md"
  _write_pending "c.md" "普通の本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "引き継ぎが 2 件ある" "フック出力"
  assert_contains "$HOOK_OUT" "改行入りの本文" "フック出力"
  assert_contains "$HOOK_OUT" "普通の本文" "フック出力"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_空白と日本語を含むファイル名でも消費できる() {
  _setup_project
  _write_pending "2026-07-31-1840 引き継ぎ メモ.md" "日本語名の本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "日本語名の本文" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/2026-07-31-1840 引き継ぎ メモ.md"
}

test_ハイフンで始まるファイル名でも消費できる() {
  _setup_project
  printf 'ハイフン名の本文\n' >"$PROJ/.claude/.handoff/pending/-n.md"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "ハイフン名の本文" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/consumed/-n.md"
}

# SKILL.md は consumed から pending へ mv で戻せると書いている。
# ln -s で戻す人がいても無音で放置しない。
test_シンボリックリンクも対象にする() {
  _setup_project
  printf 'リンク先の本文\n' >"$TEST_TMP/real.md"
  ln -s "$TEST_TMP/real.md" "$PROJ/.claude/.handoff/pending/2026-07-31-1840-link.md"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "リンク先の本文" "フック出力"
  assert_empty "$(ls -A "$PROJ/.claude/.handoff/pending")" "pending の残存"
}

test_サブディレクトリは無視する() {
  _setup_project
  mkdir -p "$PROJ/.claude/.handoff/pending/draft"
  printf '下書き\n' >"$PROJ/.claude/.handoff/pending/draft/x.md"
  _write_pending "2026-07-31-1840-a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "本文" "フック出力"
  assert_not_contains "$HOOK_OUT" "下書き" "フック出力"
  assert_file_exists "$PROJ/.claude/.handoff/pending/draft/x.md"
}

# ファイル名の昇順＝時刻の昇順という前提が破れたことに気づけること。
test_タイムスタンプで始まらない名前があれば警告する() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "本文"
  _write_pending "memo.md" "順序不明"
  _run_hook "$(_startup_payload)"
  assert_contains "$HOOK_OUT" "YYYY-MM-DD-HHMM" "フック出力"
}

test_タイムスタンプ名だけなら警告しない() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_not_contains "$HOOK_OUT" "YYYY-MM-DD-HHMM" "フック出力"
}

# ---- 出力の契約 ----------------------------------------------------------
# SessionStart の標準出力はそのままコンテキストへ入る。余計なものを出さない。

test_標準エラーは常に空である() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "本文"
  _run_hook "$(_startup_payload)"
  assert_empty "$(cat "$TEST_TMP/.hook-err")" "標準エラー"

  _write_pending "2026-07-31-1841-b.md" "本文"
  chmod 555 "$PROJ/.claude/.handoff/pending"
  _run_hook "$(_startup_payload)"
  chmod 755 "$PROJ/.claude/.handoff/pending"
  assert_empty "$(cat "$TEST_TMP/.hook-err")" "移動失敗時の標準エラー"
}

test_読み取れないファイルは無音で握りつぶさない() {
  _setup_project
  _write_pending "2026-07-31-1840-a.md" "読めない本文"
  chmod 000 "$PROJ/.claude/.handoff/pending/2026-07-31-1840-a.md"
  _run_hook "$(_startup_payload)"
  chmod 644 "$PROJ/.claude/.handoff/consumed/2026-07-31-1840-a.md" 2>/dev/null || true
  assert_contains "$HOOK_OUT" "読めなかった" "フック出力"
  assert_empty "$(cat "$TEST_TMP/.hook-err")" "標準エラー"
}

# ---- プロジェクトディレクトリの決定 --------------------------------------

test_CLAUDE_PROJECT_DIR_は_JSON_の_cwd_に優先する() {
  _setup_project
  local other="$TEST_TMP/other"
  mkdir -p "$other/.claude/.handoff/pending"
  printf 'cwd 側の引き継ぎ\n' >"$other/.claude/.handoff/pending/x.md"
  _write_pending "a.md" "PROJECT_DIR 側の引き継ぎ"
  local out
  _run_hook "$(printf '{"source":"startup","cwd":"%s"}' "$other")"
  out="$HOOK_OUT"
  assert_contains "$out" "PROJECT_DIR 側の引き継ぎ" "フック出力"
  assert_not_contains "$out" "cwd 側の引き継ぎ" "フック出力"
}

test_cwd_が存在しないディレクトリなら_PWD_へ落ちる() {
  _setup_project
  unset CLAUDE_PROJECT_DIR
  # run.sh は各テストを $TEST_TMP を CWD として実行する。そこへ pending を置く。
  mkdir -p "$PWD/.claude/.handoff/pending"
  printf 'PWD 側の引き継ぎ\n' >"$PWD/.claude/.handoff/pending/a.md"
  local out
  _run_hook '{"source":"startup","cwd":"/no/such/directory"}'
  out="$HOOK_OUT"
  assert_contains "$out" "PWD 側の引き継ぎ" "フック出力"
}
