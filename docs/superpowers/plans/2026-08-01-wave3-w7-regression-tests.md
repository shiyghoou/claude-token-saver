# wave3 W3-7 波1・波2回帰テスト補強 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #9として、波1・波2の未固定経路を既存テストへ追加し、実装の弱体化を回帰テストが検出できる状態にする。

**Architecture:** 実装コードは変更せず、既存の波別テストファイルへ実データfixtureと結果assertを追加する。D1bは既存のinstall→uninstall往復テストを変異版で実行してカバレッジを確認し、重複テストを作らない。

**Tech Stack:** Bash 3.2互換スクリプト、既存のBashテストランナー、既存のassert helper、Python製gitignore/settings補助。

## Global Constraints

- Issue #9、ブランチ`issue-9-wave3-w7-regression-tests`で作業し、mainへ直接編集しない。
- W3-7は回帰テスト追加だけとし、`install.sh`、`uninstall.sh`、`scripts/`、`lib/`、テストランナー、CI、READMEは変更しない。
- 新規テストファイルは作らず、`test/test-handoff-consume.sh`、`test/test-install.sh`、`test/test-uninstall.sh`だけを変更する。
- 各テストは、終了コードだけでなく、ファイルの内容・種別・移動前後の位置をassertする。
- 実装を弱めるRED確認はscratch copy内で行い、ブランチの実装ファイルを変更しない。
- D1bの既存テストを重複追加しない。既存テストが完全一致を守ることを変異版で確認する。

---

### Task 1: B3 サブディレクトリ非再帰消費テスト

**Files:**
- Modify: `test/test-handoff-consume.sh:223-231`の`test_サブディレクトリは移動対象にしない`

**Interfaces:**
- Consumes: `_setup_project`、`_write_pending`、`_run_consume`、`assert_file_exists`、`assert_file_missing`。
- Produces: pending直下だけを一括消費し、ネストしたファイルを残す回帰テスト。

- [ ] **Step 1: 失敗を検出できるfixtureを先に追加する**

既存テストへ、空の`draft`ではなく実ファイルを置くassertを追加する。

```bash
  mkdir -p "$PROJ/.token-saver/handoff/pending/draft"
  printf 'ネストした下書き\n' >"$PROJ/.token-saver/handoff/pending/draft/inner.md"
  _write_pending "a.md" "A"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_exists "$PROJ/.token-saver/handoff/pending/draft/inner.md"
  assert_file_missing "$PROJ/.token-saver/handoff/consumed/inner.md"
  assert_file_exists "$PROJ/.token-saver/handoff/consumed/a.md"
```

- [ ] **Step 2: 現行実装でテスト記述を確認する**

Run: `bash test/run.sh test/test-handoff-consume.sh`

Expected: 既存実装では追加テストを含めてPASS。これは実装変更ではなく回帰テスト追加であるため、現行の修正版がGREENであることを確認する。

- [ ] **Step 3: scratch mutationでREDを確認する**

完全コピー内の`test/run.sh`を使って、`scripts/handoff-consume.sh`のトップレベルglob列挙を再帰`find "$pending_dir" -type f`列挙へ置き換える。コピー内で同じテストを実行し、`pending/draft/inner.md`が`consumed/inner.md`へ移ったことによる追加テストのFAILを確認する。作業ブランチの実装ファイルは変更しない。

- [ ] **Step 4: GREEN結果を再確認する**

Run: `bash test/run.sh test/test-handoff-consume.sh`

Expected: 追加テストを含む対象ファイルがPASSし、scratch mutationの一時ファイルを残さない。

### Task 2: B5 生きたsymlinkの一括消費テスト

**Files:**
- Modify: `test/test-handoff-consume.sh`（B3テストの後ろ）

**Interfaces:**
- Consumes: `_setup_project`、`_run_consume`、`assert_file_exists`、`assert_file_missing`、`assert_contains`。
- Produces: symlink自体をconsumedへ移し、リンク先の実体を保持する回帰テスト。

- [ ] **Step 1: symlink fixtureと結果assertを書く**

```bash
test_生きたシンボリックリンクを一括消費する() {
  _setup_project
  local target="$TEST_TMP/real-note.md"
  printf 'リンク先の本文\n' >"$target"
  ln -s "$target" "$PROJ/.token-saver/handoff/pending/link.md"
  _run_consume
  assert_eq "0" "$CONSUME_STATUS" "終了コード"
  assert_file_missing "$PROJ/.token-saver/handoff/pending/link.md"
  if [ ! -L "$PROJ/.token-saver/handoff/consumed/link.md" ]; then
    _fail "symlinkを実体化せずconsumedへ移す"
  fi
  assert_contains "$(cat "$PROJ/.token-saver/handoff/consumed/link.md")" \
    "リンク先の本文" "consumedのsymlink"
  assert_file_exists "$target" "リンク先の実体"
}
```

- [ ] **Step 2: 現行実装でGREENを確認する**

Run: `bash test/run.sh test/test-handoff-consume.sh`

Expected: symlinkの種別・内容・リンク先の保持を含めてPASS。

- [ ] **Step 3: scratch mutationでREDを確認する**

完全コピー内の`handoff-consume.sh`で、引数なし列挙の`[ -f "$f" ]`へ`[ ! -L "$f" ]`を加えてsymlinkを除外する変異を作る。追加テストが`consumed/link.md`不在でFAILすることを確認する。

- [ ] **Step 4: GREEN結果を再確認する**

Run: `bash test/run.sh test/test-handoff-consume.sh`

Expected:対象テストPASS。作業ツリーにscratch mutationを持ち込まない。

### Task 3: C4 dotfile移行テスト

**Files:**
- Modify: `test/test-install.sh`（旧パス移行テスト群）

**Interfaces:**
- Consumes: `_setup_target`、`_run_install`、`TARGET`、`assert_eq`、`assert_file_missing`。
- Produces:旧pendingにあるdotfileが新pendingへ移行される回帰テスト。

- [ ] **Step 1: dotfileの移行テストを書く**

```bash
test_旧パスのdotfile引き継ぎを新パスへ移す() {
  _setup_target
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'dotfileの本文\n' >"$TARGET/.claude/.handoff/pending/.draft.md.swp"
  _run_install
  assert_eq "dotfileの本文" \
    "$(cat "$TARGET/.token-saver/handoff/pending/.draft.md.swp")" \
    "dotfileの移行内容"
  assert_file_missing "$TARGET/.claude/.handoff/pending/.draft.md.swp" \
    "旧側のdotfile"
}
```

- [ ] **Step 2: 現行実装でGREENを確認する**

Run: `bash test/run.sh test/test-install.sh`

Expected: dotfileを含むinstallテストがPASSし、旧側のdotfileが残らない。

- [ ] **Step 3: scratch mutationでREDを確認する**

完全コピー内の`install.sh`の`cts_migrate_dir`列挙から`"$from"/.*`を除外する変異を作る。追加テストが新側のdotfileを読めずFAILすることを確認する。

- [ ] **Step 4: GREEN結果を再確認する**

Run: `bash test/run.sh test/test-install.sh`

Expected:対象テストPASS。

### Task 4: uninstallのsettings生成前提テスト

**Files:**
- Modify: `test/test-uninstall.sh:210-218`の`test_残った_settings_は妥当な_JSON_である`

**Interfaces:**
- Consumes: `_setup_target`、`_run_install`、`SETTINGS`、`assert_file_exists`、既存のJSON検証。
- Produces: installがsettingsを生成しない回帰を検出する前提assert。

- [ ] **Step 1: `_run_install`直後に存在assertを追加する**

```bash
  _run_install
  assert_file_exists "$SETTINGS" "install後のsettings.local.json"
  _run_uninstall
  # 中身が空なら uninstall が消すので、残っている場合だけ検査する。
  [ -f "$SETTINGS" ] || return 0
```

- [ ] **Step 2: 現行実装でGREENを確認する**

Run: `bash test/run.sh test/test-uninstall.sh`

Expected: install直後のsettings存在と、uninstall後に残る場合のJSON妥当性がPASS。

- [ ] **Step 3: scratch mutationでREDを確認する**

完全コピー内の`install.sh`で、`settings-hooks.py install`の実行を no-op に置き換える。追加した存在assertがFAILし、従来の`[ -f ] || return 0`だけでは見逃していた回帰を捕捉することを確認する。

- [ ] **Step 4: GREEN結果を再確認する**

Run: `bash test/run.sh test/test-uninstall.sh`

Expected:対象テストPASS。

### Task 5: D1b既存テストの変異検証

**Files:**
- Verify only: `test/test-uninstall.sh:test_同じ接頭辞のユーザーのコメント行を誤認しない`
- Verify only: `lib/gitignore-block.py:find_blocks`

**Interfaces:**
- Consumes: `GITIGNORE_START`、既存のinstall→uninstall往復fixture、`.gitignore`内容assert。
- Produces: D1bを重複テストなしで守れている証跡。

- [ ] **Step 1: 既存テストを単独実行する**

Run: `bash test/run.sh test/test-uninstall.sh`

Expected: `test_同じ接頭辞のユーザーのコメント行を誤認しない`がPASSし、利用者のコメント・他のignore行が残る。

- [ ] **Step 2: scratch mutationでREDを確認する**

完全コピー内の`lib/gitignore-block.py:find_blocks`で、`s == START`を` s.startswith(START)`相当へ変える。既存テストが利用者コメント行の消失または往復後の内容不一致でFAILすることを確認する。

- [ ] **Step 3: GREEN結果を再確認する**

Run: `bash test/run.sh test/test-uninstall.sh`

Expected:現行実装の完全一致判定でPASS。`lib/gitignore-block.py`はブランチ上で変更しない。

### Task 6: 回帰確認、台帳、コミット

**Files:**
- Verify: `test/test-handoff-consume.sh`
- Verify: `test/test-install.sh`
- Verify: `test/test-uninstall.sh`
- Modify only if required by measured lower-bound increase: `test/expected-min-count`

- [ ] **Step 1: 追加テストを対象別に実行する**

```bash
bash test/run.sh test/test-handoff-consume.sh
bash test/run.sh test/test-install.sh
bash test/run.sh test/test-uninstall.sh
```

各対象で失敗0件を確認する。

- [ ] **Step 2: 台帳の実測値を確認する**

```bash
bash test/run.sh
```

総件数とファイル別件数が台帳下限以上であることを確認し、必要な場合だけ`test/expected-min-count`を実測値へ更新する。

- [ ] **Step 3: 構文・空白・差分範囲を確認する**

```bash
bash -n test/test-handoff-consume.sh test/test-install.sh test/test-uninstall.sh
git diff --check
git diff --name-only origin/main...HEAD
```

差分に実装・CI・W3-7対象外ファイルがないことを確認する。

- [ ] **Step 4: 実装コミットを作成する**

```bash
git add test/test-handoff-consume.sh test/test-install.sh test/test-uninstall.sh test/expected-min-count
git commit -m "test: W3-7の波1・波2回帰経路を固定する"
```

`test/expected-min-count`に差分が無い場合は、存在する3テストファイルだけをstageする。

### Task 7: 独立レビューとPR準備

- [ ] **Step 1: レビュー前のSHAと検証結果を記録する**

BaseはIssue #9ブランチの起点`028cf690904c000e73e8ac111318d900c735da81`、Headは実装コミット後のHEADとする。対象はB3/B5/C4/settings前提/D1b、Bash互換性、fixtureの実効性、W3-7スコープ逸脱である。

- [ ] **Step 2: 実装者と別のサブエージェントへ敵対的レビューを依頼する**

レビューは読み取り専用とし、Critical・Important・Minor、file:line、影響、修正案、Ready to merge判定を返させる。指摘があれば修正→対象テスト→全件テスト→再レビューを繰り返す。

- [ ] **Step 3: PRへレビュー結果を記録する**

レビュー識別子、Base/Head SHA、指摘と対応、再レビュー結果、検証コマンドを日本語コメントへ記録する。マージは行わず、ユーザーへ依頼する。
