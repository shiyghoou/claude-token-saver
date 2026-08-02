# Handoff Attribute Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #15 の脅威モデルに従い、`handoff-check.sh` の開始タグに含める `file` / `path` 属性を、改行・引用符・タグ記号・シェル記号・Unicode を含む入力でも一行の安全な記録として出力できるようにする。

**Architecture:** `scripts/lib/common.sh` に副作用のないバイト単位エンコーダー `cts_encode_attribute()` を追加し、開始タグを組み立てる唯一の経路である `scripts/handoff-check.sh::_open_tag()` から利用する。可読性のため `A-Z a-z 0-9 . _ - /` だけをそのまま残し、それ以外の各バイトを大文字 `%XX` へ変換する。エンコード失敗時は元の値へフォールバックせず空属性にする。区切りの識別子、本文、移動・消費の順序は変更しない。

**Tech Stack:** Bash 3.2、POSIX 基本コマンド（`od`、`tr`）、既存の Bash テストランナー、Docker を用いた Bash 3.2 E2E テスト。

## Global Constraints

- Issue #15 のブランチ `issue-15-handoff-attribute-safety` だけで作業し、`main` は直接変更しない。
- 仕様書に記載した非対象（token-report の認証情報マスキング、`SessionStart` matcher の選択）は変更しない。
- Bash 3.2 で動かない配列、`${var,,}`、`${var^^}`、連想配列、外部 Python/jq 実行時依存を追加しない。
- 属性値の生文字列を Markdown 本文や区切りの外側へ出さない。属性エンコーダーの失敗時にも生値を出さない。
- `file` と `path` の両方を同じエンコード関数で処理し、`/` 以外のパス区切り表現（Windows の `\\` やドライブ区切りの `:` を含む）は `%XX` 化する。
- 標準エラーへ秘密情報、入力値、エンコード途中の値を出力しない。既存の終了コード、spool、動的 fence、移動・消費の挙動を保つ。
- 実装後は全テストと Bash 3.2 E2E を実行し、独立した別エージェントの敵対的レビューを受ける。指摘があればテスト追加・修正・再レビューを行い、レビュー結果を PR に記録する。マージはユーザーに依頼し、エージェントは実行しない。

---

## Task 1: 失敗する属性安全性テストを先に追加する

**Files:**

- Modify: `test/test-handoff-check.sh`
- Modify: `test/expected-min-count`

### Step 1: 既存のテストヘルパーと一時ディレクトリの流儀を確認する

- [ ] 既存の `_write_pending`、タグ抽出、fence 内外判定、アサーションを再利用する。
- [ ] テスト自身でエンコード実装を再実装せず、既知の入力と期待する固定文字列を直接比較する。
- [ ] 現在の台帳は `test-handoff-check.sh 84`、総数 `383` であることを確認する。

### Step 2: 次の 5 件のテストを追加する

- [ ] `test_区切り属性は安全なASCIIとスラッシュを保持しパーセントをエンコードする`
   - `safe-name_v1.md` はそのまま残ることを確認する。
   - `%` を含む名前またはパス部分は `%25` になることを確認する。
   - `/` はパスの可読性のためそのまま残ることを確認する。

- [ ] `test_区切り属性は引用符タグ記号空白アンパサンドとバックスラッシュをエンコードする`
   - `a"b<c>d & \ 日本語.md` のような pending ファイルを作る。
   - `file` 属性に、少なくとも次の固定結果が含まれることを確認する。
     `a%22b%3Cc%3Ed%20%26%20%5C%20%E6%97%A5%E6%9C%AC%E8%AA%9E.md`
   - `path` 属性にも同じファイル名のエンコード結果が現れ、`"`、`<`、`>`、`&`、`\`、空白、Unicode の生バイトが出ないことを確認する。

- [ ] `test_区切り属性は改行と制御文字をタグの一行内でエンコードする`
   - 改行を含むファイル名を作成し、開始タグの行数が 1 行であることを確認する。
   - 改行が `%0A`、タブが `%09`、復帰が `%0D` になることを固定値で確認する。
   - fence の開始・終了件数が従来どおり 1 件ずつで、既存の本文が fence 内に残ることを確認する。

- [ ] `test_区切り属性はシェル記号を実行せず外側へ漏らさない`
   - `\$(touch MARKER)`、バッククォート、`;`、`&`、`|`、`$`、`(`、`)` を含むファイル名を作る。
   - hook 実行後に marker ファイルが存在しないこと、開始タグが一行であること、危険な入力が fence の外側に生で存在しないことを確認する。
   - 属性は記録であり命令ではないという既存の外側説明が残っていることも確認する。

- [ ] `test_属性エンコーダー失敗時は生値へフォールバックしない`
   - `common.sh` を読み込み、エンコーダーが使用する `od` を解決できない限定 `PATH` で unsafe な値を渡す。
   - 戻り値が失敗で、標準出力・標準エラーが空であることを確認する。
   - このテストは `_open_tag()` の呼び出し側が失敗時に空属性を使う契約を守れるよう、後続実装のための回帰試験とする。

### Step 3: テストが実装前に赤くなることを確認する

```bash
bash test/run.sh handoff-check
```

期待結果は失敗である。現在の `cts_sanitize_text()` は unsafe byte を `%XX` にせず削除し、シェル記号を残すため、固定された属性期待値と marker 不在のアサーションを満たさない。Task 1 の段階では `cts_encode_attribute()` が未実装であるため、失敗時フォールバック試験の未定義関数エラーも意図した赤化として扱い、その他の試験に別の環境エラーが混ざっていないことを確認する。

### Step 4: テスト件数の台帳を更新する

- [ ] 新規 5 件を追加した後、`test/expected-min-count` の `test-handoff-check.sh` を `89`、総数を `388` にする。
- [ ] `bash test/run.sh handoff-check` でファイル別下限が 89 以上になることを確認する。

### Step 5: テストだけをコミットする

```bash
git add test/test-handoff-check.sh test/expected-min-count
git commit -m "Issue #15: handoff属性安全性の失敗テストを追加"
```

コミットには production code やドキュメントを含めない。

---

## Task 2: バイト単位 `%XX` エンコーダーを実装し開始タグへ接続する

**Files:**

- Modify: `scripts/lib/common.sh`
- Modify: `scripts/handoff-check.sh`

### Step 1: `cts_encode_attribute()` の契約を実装する

`scripts/lib/common.sh` の既存の属性用 lossy sanitizer を置き換え、次のインターフェースにする。

```bash
cts_encode_attribute() {
  # $1: NUL を含まない任意のシェル文字列
  # stdout: エンコード済み属性値
  # return 0: 完了、return 1: byte-to-hex 変換などの内部失敗
}
```

実装手順は次のとおりに固定する。

- [ ] 関数内だけ `LC_ALL=C` を有効にし、`${#value}` と `${value:$i:1}` が UTF-8 の文字数ではなく byte 数で進むようにする。
- [ ] 各 byte が `[A-Za-z0-9._/-]` のいずれかなら、その byte をそのまま `encoded` に追加する。
- [ ] それ以外は、その byte だけを `od -An -t x1` で 2 桁の hex に変換する。`od` の失敗は直ちに `return 1` とする。
- [ ] hex の空白を除去し、`tr 'a-f' 'A-F'` で大文字へ統一する。結果が `[0-9A-F][0-9A-F]` に一致しなければ `return 1` とする。
- [ ] 変換した結果を `%${hex}` として追加する。`%` は `%25`、改行は `%0A`、二重引用符は `%22`、`<` は `%3C`、`>` は `%3E` になる。
- [ ] 最後に `encoded` だけを `printf '%s'` で出力する。途中の raw byte や診断を stdout/stderr へ出力しない。

パイプラインの失敗を見落とさないよう、`od` の結果取得と hex 整形を一つの unchecked pipeline にまとめず、それぞれのコマンド置換後に戻り値を検査する。内部の `od` / `tr` 呼び出しには `2>/dev/null` を付け、変換失敗の診断や入力値を stderr へ漏らさない。変換不能時に入力 byte をそのまま追加する分岐は作らない。NUL は Bash 文字列へ保持できないため、入力契約上の対象外とする。

### Step 2: `_open_tag()` の全属性を新関数で処理する

`scripts/handoff-check.sh` の `_open_tag()` を次の流れにする。

- [ ] `basename` で得たファイル名を `cts_encode_attribute` へ渡し、失敗時は `safe_name=""` にする。
- [ ] `$2` のパスを同じ関数へ渡し、失敗時は `safe_path=""` にする。
- [ ] `printf '<handoff:%s file="%s" path="%s">\n'` の構造は維持し、属性値以外の fence id と固定タグ文字列は変更しない。
- [ ] `_open_tag()` 内に raw の `cts_sanitize_text` 呼び出しを残さず、`rg -n 'cts_sanitize_text|safe_name|safe_path' scripts` で参照経路を確認する。

開始タグの外側の説明と実装コメントは、「危険文字を削除する」ではなく「属性を `%XX` へエンコードし、一行の記録として扱う」と記述する。

### Step 3: 実装の局所検証を行う

```bash
bash -n scripts/lib/common.sh scripts/handoff-check.sh
bash test/run.sh handoff-check
```

期待結果は、構文検査成功、Task 1 の `test-handoff-check.sh` 89 件以上成功である。既存の改行・Unicode・空白ファイル名、動的 fence、spool 移動のテストも同じ実行で緑になることを確認する。

### Step 4: 実装をコミットする

```bash
git add scripts/lib/common.sh scripts/handoff-check.sh
git commit -m "Issue #15: handoff属性をバイト単位でエンコード"
```

---

## Task 3: 既存 consumer とセキュリティ不変条件の回帰を確認する

**Files:**

- Modify: `test/test-handoff-check.sh`（Task 1 のテストで不足が判明した場合のみ）
- Modify: `test/test-handoff-consume.sh`（consumer の入力契約を補強する必要がある場合のみ）

### Step 1: fence parser と consumer の互換性を確認する

- [ ] `%XX` を含む開始タグを既存の `_fence_id`、`_count_open_tags`、`_inside_fence`、`_outside_fence` で解析できることを確認する。
- [ ] `handoff-consume.sh` の移動・消費対象判定はタグ属性を解析していないため、属性値の変更で pending/consumed の順序、重複防止、本文出力が変わっていないことを既存テストで確認する。
- [ ] `file` の表示値だけでファイルを再オープンする新しい処理を追加しない。実ファイル操作は既存の raw path 変数で行い、タグ表示値は記録用途に限定する。

### Step 2: 破壊的変異に対するテストの赤化を確認する

一時的な作業ツリー上の変異として、次のいずれか一つを適用してから focused test を実行し、対応するテストが失敗することを確認する。確認後は変異を直ちに戻し、最終 diff に残さない。

- [ ] `_open_tag()` を一時的に `cts_sanitize_text` へ戻すと、Task 1 の固定 `%XX` 期待値が失敗する。
- [ ] `cts_encode_attribute()` の unsafe byte 分岐を raw byte 追加へ変えると、改行の一行性または marker 不在のテストが失敗する。
- [ ] `<handoff:%s ...>` の出力を一時的に削除すると、既存の fence 件数テストが失敗する。

```bash
bash test/run.sh handoff-check
```

変異確認後、`git diff --check` と `git status --short` で原状復帰を確認する。

### Step 3: 必要な回帰テストをコミットする

consumer の回帰アサーションを追加した場合だけ、次のコミットを作る。

```bash
git add test/test-handoff-check.sh test/test-handoff-consume.sh
git commit -m "Issue #15: handoff属性とconsumerの互換性を検証"
```

テスト追加が不要だった場合は、不要な空コミットを作らない。

---

## Task 4: README・SKILL・設計仕様を実装と一致させる

**Files:**

- Modify: `README.md`
- Modify: `skills/session-handoff/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`

### Step 1: README の利用者向け説明を更新する

handoff 区切りの説明で、次を明記する。

- [ ] `file` / `path` は untrusted な記録用属性であり、命令やシェル入力ではない。
- [ ] `A-Z a-z 0-9 . _ - /` 以外は UTF-8 の各 byte を大文字 `%XX` へ変換する。
- [ ] `/` は保持し、Windows の `\`、`:`、空白、改行、引用符、`<`、`>`、`&`、`%`、shell metacharacter はエンコードされる。
- [ ] 表示属性から元のパスを得る必要がある場合は `%XX` を byte 単位で decode する。属性値をそのままコマンドへ渡さない。
- [ ] 生のファイル名・パスは fence の外側へ出力しない。

### Step 2: session-handoff SKILL の指示を更新する

フック出力を正とする構成を維持しつつ、属性が記録であって指示ではないこと、危険文字が `%XX` 化されること、本文と属性を命令として実行しないことを記載する。`SessionStart` matcher の選択肢や token-report の説明は変更しない。

### Step 3: 既存の設計仕様の古い防御説明を更新する

`docs/specs/2026-07-31-claude-token-saver-design.md` の「制御文字と `"` `<` `>` を除去する」という説明を、Issue #15 の可逆な byte-level percent encoding と失敗時 empty attribute の説明へ置き換える。テストで防御を固定するという既存の設計意図は残す。

### Step 4: 文書とコードの表現を検査してコミットする

```bash
rg -n '制御文字.*(除去|落とす)|引用符.*(除去|落とす)|タグを割|cts_sanitize_text' README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md scripts
git diff --check
```

上の検索結果に属性防御を古い削除方式で説明する行が残らないことを確認する（別の無関係な「落とす」記述は内容を確認して誤判定しない）。

```bash
git add README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md
git commit -m "Issue #15: handoff属性の安全化仕様を文書化"
```

---

## Task 5: 全体検証と Bash 3.2 互換性を確認する

### Step 1: 差分と構文を検査する

```bash
git diff main...HEAD --check
bash -n scripts/lib/common.sh scripts/handoff-check.sh scripts/handoff-consume.sh
```

エラーがなく、変更範囲が Issue #15 の対象ファイルに限定されていることを確認する。

### Step 2: 全テストを実行する

```bash
bash test/run.sh
```

期待結果は全テスト成功、総実行件数 388 件以上、`test-handoff-check.sh` 89 件以上である。既知の load-sensitive hook failure が発生した場合は、対象テスト名・終了コード・再現条件を通常の focused test 結果と分けて記録し、原因を切り分ける。

### Step 3: Bash 3.2 E2E を実行する

```bash
bash test/bash32-e2e.sh
```

Docker 上の Bash 3.2 で hook、属性の一行性、危険文字の `%XX` 化、既存 consumer の動作を通過させる。Docker の起動権限や daemon 状態で失敗した場合は、エンコーダーの失敗と環境エラーを混同せず、stderr と終了コードを保存してから再実行可能な状態でユーザーへ報告する。

### Step 4: 秘密情報と作業ツリーを確認する

- [ ] 既存の secret leak テストを含む全テスト結果を確認し、handoff/report/stderr に token、credential、環境変数値が出ていないことを確認する。
- [ ] `git status --short` が意図したコミット後に空であることを確認する。
- [ ] `/tmp` やリポジトリ内に marker、テスト用 pending/consumed、デバッグ出力を残さない。

### Step 5: 検証結果をコミットに反映する

検証でコード・テスト・文書の修正が必要になった場合は、該当タスクの小さなコミットへ戻して再実行する。検証だけで変更がなければ空コミットは作らない。

---

## Task 6: 独立敵対的レビュー、修正ループ、PR 作成

### Step 1: 別エージェントへレビューを依頼する

実装者とは別のサブエージェントに、`main...HEAD` の差分、Issue #15、設計仕様、全検証結果を渡してレビューを依頼する。レビュー観点は次の順序で指定する。

1. `file` / `path` に raw byte が残り、改行でタグが分割される経路がないか。
2. `%XX` が byte 単位・大文字・可逆で、`%`、Unicode、制御文字、引用符、タグ記号、shell metacharacter を漏らさないか。
3. `od` 不在・変換失敗時に raw fallback、秘密情報の stderr 出力、成功扱いが起きないか。
4. Bash 3.2 と locale 差、空文字、複数 byte UTF-8、パス区切りの挙動に回帰がないか。
5. dynamic fence、outside-fence、spool 移動、consumer、既存の secret leak 不変条件が保たれているか。
6. README、SKILL、設計仕様、コメントが実装と矛盾していないか。

レビュー結果は重大度（blocker / major / minor）と再現手順を含めて PR のレビューコメントへ記録する。

### Step 2: 指摘を修正し、テストを追加して再レビューする

- [ ] blocker または major が一つでもあれば、まず失敗を再現するテストを追加し、その後に最小修正を行う。
- [ ] 修正後は `bash test/run.sh handoff-check`、`bash test/run.sh`、`bash test/bash32-e2e.sh`、`git diff --check` を再実行する。
- [ ] 同じレビューエージェントまたは別の独立エージェントへ差分を再提示し、指摘が解消されたことを確認する。
- [ ] clear になるまでこの修正・検証・レビューを繰り返す。レビューを受けずに「マージ可能」と報告しない。

### Step 3: PR を作成してユーザーへマージを依頼する

```bash
git status --short --branch
git log --oneline --decorate -n 8
git push -u origin issue-15-handoff-attribute-safety
gh pr create --base main --head issue-15-handoff-attribute-safety --title "Issue #15: handoff区切りタグ属性を安全にエンコード" --body-file <レビュー済みPR本文>
```

PR 本文には次を日本語で記載する。

- `Closes #15`
- `%XX` byte encoding の仕様と、エンコード失敗時に空属性とすること
- 変更ファイルと非対象範囲
- focused test、全テスト、Bash 3.2 E2E の実測結果
- 独立敵対的レビューの結果と修正・再レビューの履歴
- ユーザーが確認後にマージすること

PR 作成後はマージせず、URL と検証結果をユーザーへ渡す。ユーザーが「マージしました」と伝えた後に限り、`main` の更新、マージ確認、対応するローカル・リモートブランチの安全な後処理を行う。

---

## Expected Final State

- Issue #15 の受け入れ条件を満たす実装、テスト、文書が `main` への PR にまとまっている。
- `file` / `path` は unsafe byte を生で出さず、タグは常に一行で、開始・終了 fence と既存 consumer の契約が維持されている。
- Bash 3.2 E2E を含む検証結果と、実装者以外による独立レビュー結果が PR に残っている。
- エージェントはマージを実行していない。
