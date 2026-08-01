# wave2 引き継ぎ実行時挙動 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #2の波2として、引き継ぎの実行時境界・消費競合・出力切断時のデータ保全を強化する。

**Architecture:** 既存のBashフックと共通ライブラリを維持し、`pending/.inflight.<pid>/`へのclaim、spool出力、stdout成功後のcommitという三段階にする。共通移動処理は`mkdir`による宛先ロックで`.dupN`の競合を原子的に解決する。

**Tech Stack:** Bash 3.2互換のシェルスクリプト、POSIX系ファイル操作、既存の自前Bashテストランナー。

## Global Constraints

- Issue #2の波2対象ファイルだけを実装変更する。
- 通常ファイルは1件8,192バイト、合計32,768バイト、最大5件を超えてstdoutへ注入しない。
- SessionStartの発火源は`startup`と`clear`だけにする。`resume`、`compact`、`fork`、不明値では消費しない。
- ファイル名・パス由来の文字列は区切りタグ属性内に限定し、区切り外の固定文へ埋め込まない。
- フックは標準エラーを汚さず、終了コード0でセッション起動を妨げない。
- `AGENTS.md`と`CLAUDE.md`は変更しない。

---

### Task 1: 波2の回帰テストをREDにする

**Files:**
- Modify: `test/test-handoff-check.sh`
- Modify: `test/test-handoff-consume.sh`

**Interfaces:**
- Consumes: 現行の`_setup_project`、`_run_hook`、`_run_consume`、既存assert helper。
- Produces: W2-1〜W2-8とW2-9の失敗を再現するテスト。実装変更なしで失敗することを確認する。

- [ ] **Step 1: W2-1/W2-7/W2-8の失敗テストを書く**

`test/test-handoff-check.sh`へ、ハードリンク、ディレクトリシンボリックリンク、FIFO、`source=resume`のテストを追加する。各テストは本文が出ないこと、固定の異常報告が出ること、通常の後続本文が配送されること、`resume`ではpendingが残ることを検証する。

- [ ] **Step 2: W2-2/W2-3/W2-4/W2-6の失敗テストを書く**

異常項目を11件以上作って報告の上限を確認し、最初のclaimだけを失敗させる`mv` shadowで後続ファイルの配送を確認する。8192バイトのファイルを5件作り、4件だけが配送され5件目がpendingに残ることを確認する。`bash "$HOOK" | head -1`を使い、stdout切断後に本文がpendingへ戻ることを確認する。

- [ ] **Step 3: W2-5/W2-9の失敗テストを書く**

`test/test-handoff-consume.sh`へ、shadowした`mv`で先頭候補だけを失敗させても後続候補を消費するテストを追加する。同名宛先へ並行して移すテストを追加し、既存本文が上書きされず、新しい本文が`.dupN`へ残ることを確認する。

- [ ] **Step 4: 対象テストを実行してREDを確認する**

```bash
bash test/run.sh test/test-handoff-check.sh
bash test/run.sh test/test-handoff-consume.sh
```

期待結果は、追加したテストが現行実装の欠陥を理由に失敗し、既存テストの失敗が追加テストの記述ミスではないことを確認できることである。

- [ ] **Step 5: テスト追加をコミットする**

```bash
git add test/test-handoff-check.sh test/test-handoff-consume.sh
git commit -m "test: 波2の引き継ぎ境界を回帰テストで固定する"
```

### Task 2: 共通移動処理と手動一括消費をGREENにする

**Files:**
- Modify: `scripts/lib/common.sh`
- Modify: `scripts/handoff-consume.sh`
- Test: `test/test-handoff-consume.sh`

**Interfaces:**
- Consumes: Task 1のclaim競合・一括失敗テスト。
- Produces: `cts_move_file`、宛先予約、既存`cts_consume_file`互換、失敗後も続行する一括消費。

- [ ] **Step 1: 宛先ロック付き移動ヘルパーを実装する**

`common.sh`に、`dest.cts-lock`を`mkdir`で確保してから宛先の存在（通常ファイル・ディレクトリ・リンク）を再確認する移動処理を追加する。予約先は`CTS_RESERVED_DEST`、ロックは`CTS_RESERVED_LOCK`、単純移動先は`CTS_MOVED_DEST`で呼び出し側へ返す。予約候補は元のbasename、`.dup1`以降とし、候補探索には有限の上限を設ける。

- [ ] **Step 2: `cts_consume_file`を共通処理へ委譲する**

既存の`cts_consume_file`の戻り値と`CTS_CONSUMED_DEST`を維持し、内部だけを新しい原子的移動処理へ置き換える。壊れたリンクも既存宛先として扱い、上書きしない。

- [ ] **Step 3: 一括モードを最後まで処理する**

`handoff-consume.sh`の引数なしループを`rc=1`を記録して継続する形へ変更し、全候補を試した後に`rc`を返す。引数指定モードの挙動は維持する。

- [ ] **Step 4: 共通・consumeテストを実行してGREENを確認する**

```bash
bash test/run.sh test/test-handoff-consume.sh
```

- [ ] **Step 5: 共通処理の変更をコミットする**

```bash
git add scripts/lib/common.sh scripts/handoff-consume.sh test/test-handoff-consume.sh
git commit -m "fix: 引き継ぎ移動の競合と一括失敗を扱う"
```

### Task 3: handoff-checkの分類・上限・トランザクションをGREENにする

**Files:**
- Modify: `scripts/handoff-check.sh`
- Test: `test/test-handoff-check.sh`

**Interfaces:**
- Consumes: Task 1のW2-1〜W2-4、W2-6、W2-8テストとTask 2の共通移動API。
- Produces: ハードリンク等の異常分類、claim/output/commit、シグナル時の復元、診断上限、`resume`除外。

- [ ] **Step 1: 発火源とfind分類を修正する**

`resume`を通常の発火caseから外す。通常ファイルの検索からリンク数2以上を除外してハードリンク配列へ入れ、リンク切れ・置き場外リンク・リンク先ディレクトリ・FIFOなどを異常配列へ入れる。実ディレクトリは既存どおり無視する。

- [ ] **Step 2: claimと予約済みcommit配列を追加する**

候補ファイルを`pending/.inflight.<pid>/`へ移し、`consumed/`の宛先を予約する。claim失敗はスロット・バイトを消費せず、後続候補を続けて試す。合計上限を超える候補から先はpendingへ残す。

- [ ] **Step 3: spoolと復元trapを追加する**

既存の出力生成をspoolへ向け、生成後にstdoutへ`cat`する。`cat`失敗、HUP、INT、TERM、PIPEでは未commitのinflightをpendingへ戻し、成功したcommitだけ復元対象から除く。stdout送信成功後に予約済み宛先へcommitし、spoolと空ディレクトリを片付ける。

- [ ] **Step 4: 診断を固定文と区切り属性へ制限する**

消費失敗と異常項目をそれぞれ最大10件だけ詳細表示し、超過分は件数のみ表示する。ファイル名・パスは`_open_tag`の属性に限定する。本文の切り詰め、読み取り失敗、持ち越しの既存出力を維持する。

- [ ] **Step 5: handoff-checkテストを実行してGREENを確認する**

```bash
bash test/run.sh test/test-handoff-check.sh
```

- [ ] **Step 6: handoff-check変更をコミットする**

```bash
git add scripts/handoff-check.sh test/test-handoff-check.sh
git commit -m "fix: 引き継ぎフックの境界と配送を安全化する"
```

### Task 4: ドキュメントとテスト台帳を実装へ追随させる

**Files:**
- Modify: `skills/session-handoff/SKILL.md`
- Modify: `test/expected-min-count`
- Test: `test/test-handoff-check.sh`

**Interfaces:**
- Consumes: Task 3で確定した定数、発火源、claim/commitの振る舞い。
- Produces: 実装と一致する利用者向け説明と、追加テストを守る実行件数下限。

- [ ] **Step 1: SKILL.mdの上限・発火源・異常項目の説明を更新する**

1件8KB、合計32KB、最大5件の実装値、`startup`/`clear`のみの発火、ハードリンク等を本文に注入しないこと、stdout切断時にpendingへ戻ることを記載する。合計判定が加算後に膨らむという旧説明を削除する。

- [ ] **Step 2: SKILL.md一致テストを追加または更新する**

既存の定数一致テストに、`resume`を発火源として記載しないことと、inflight復元の説明を検証する条件を追加する。

- [ ] **Step 3: 実測したテスト件数で台帳を更新する**

```bash
bash test/run.sh
```

出力の総件数と`test-handoff-check.sh`、`test-handoff-consume.sh`の件数を`test/expected-min-count`へ反映する。

- [ ] **Step 4: ドキュメント変更をコミットする**

```bash
git add skills/session-handoff/SKILL.md test/test-handoff-check.sh test/expected-min-count
git commit -m "docs: 波2の引き継ぎ境界を記録する"
```

### Task 5: 全体検証とレビュー準備

**Files:**
- Verify: Issue #2の波2対象差分

- [ ] **Step 1: 完全テストを実行する**

```bash
bash test/run.sh
```

成功件数、失敗0件、台帳下限を確認する。

- [ ] **Step 2: 構文・差分検査を実行する**

```bash
bash -n scripts/handoff-check.sh scripts/handoff-consume.sh test/test-handoff-check.sh test/test-handoff-consume.sh
git diff --no-renames --check
git diff --no-renames --name-only b0bd9ac5bf809d015a8b36257f549ba470bda714..HEAD
```

差分パスが波2対象と計画書・設計書に限定されていることを確認する。

- [ ] **Step 3: 別エージェントへ敵対的レビューを依頼する**

Base SHAを`b0bd9ac5bf809d015a8b36257f549ba470bda714`、Head SHAを実装完了時の完全SHAとして固定し、W2-1〜W2-9、データ消失、stdout境界、Bash 3.2互換、テスト不足を重点にレビューする。指摘があれば修正・再検証・再レビューを行う。

- [ ] **Step 4: PRへレビュー記録を残す**

レビュアー識別子、Base/Head SHA、対象コミット、優先度、blocking判定、対応、再レビュー結果、検証コマンドを日本語で記録する。
