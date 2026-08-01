# Wave 4 Documentation and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #11の波4として、現行実装の保証範囲に合わせて説明を修正し、CIでスキップ防止・Shell構文検査・ShellCheckを常時実行する。

**Architecture:** ランタイムコードは変更せず、説明とGitHub Actionsの検査ゲートだけを更新する。CIが検査するファイル集合は `git ls-files -z -- '*.sh'` に統一し、構文検査とShellCheckで同じ対象を個別に検査する。既存のbash 3.2 E2Eジョブは独立した互換性検証として維持する。

**Tech Stack:** Bash、GitHub Actions、Ubuntu runner、ShellCheck、既存の `bash test/run.sh` テストランナー。

## Global Constraints

- Issue #11作成後の `issue-11-wave4-docs-ci` ブランチだけで作業し、mainへ直接編集しない。
- 製品ランタイムの挙動、テストランナーの検出ロジック、新機能は変更しない。
- CIではGit管理下の全 `*.sh` を `bash -n` とShellCheckの対象にする。
- CIのテスト実行には `CTS_NO_SKIP=1` を設定する。
- handoff注入上限は1ファイル8KB、合計32KB、最大5ファイルであり、現行説明と一致するため変更しない。
- 各実装単位をコミットし、PR作成後のマージはユーザーへ依頼する。

---

### Task 1: CIの構文・静的検査とスキップ防止を追加する

**Files:**
- Modify: `.github/workflows/test.yml:17-40`
- Test: Git管理下の全 `*.sh`、既存の `test/run.sh`

**Interfaces:**
- Consumes: checkout済みのGit管理下ファイル一覧とUbuntu runnerのbash
- Produces: 構文検査・ShellCheck・スキップなしテストを含む通常CIジョブ

- [ ] **Step 1: 現行CIとローカル対象ファイルを確認する**

Run:

```bash
git ls-files -z -- '*.sh' | while IFS= read -r -d '' script; do
  printf '%s\n' "$script"
done
sed -n '1,90p' .github/workflows/test.yml
```

Expected: `install.sh`、`uninstall.sh`、`scripts/`、`test/` 配下の管理対象スクリプトが列挙され、通常ジョブのテスト実行が `bash test/run.sh` のままである。

- [ ] **Step 2: 失敗条件を先に確認するため、既存の個別構文検査を実行する**

Run:

```bash
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(git ls-files -z -- '*.sh')
```

Expected: 現行の全シェルスクリプトで終了コード0になる。失敗した場合はCI変更を進めず、該当スクリプトの原因を記録する。

- [ ] **Step 3: `.github/workflows/test.yml` にファイル単位の `bash -n` を追加する**

通常ジョブのidentity設定後、テスト実行前に次を追加する。

```yaml
      - name: シェルスクリプトの構文を検査する
        run: |
          while IFS= read -r -d '' script; do
            bash -n "$script"
          done < <(git ls-files -z -- '*.sh')
```

ファイルを一度の `bash -n` にまとめず、ループ本体の失敗がジョブ失敗になる形を保つ。

- [ ] **Step 4: CIにShellCheckの導入と実行を追加する**

次の2ステップを構文検査の後、テスト実行の前に追加する。

```yaml
      - name: ShellCheckを導入する
        run: |
          sudo apt-get update
          sudo apt-get install --yes shellcheck
          shellcheck --version

      - name: ShellCheckを実行する
        run: |
          git ls-files -z -- '*.sh' | xargs -0 shellcheck --shell=bash
```

ShellCheckの警告を根拠なく除外せず、既存コードの実際の指摘が出た場合はその指摘を確認して最小限の修正または正当な行内注記を行う。

- [ ] **Step 5: テストステップへ `CTS_NO_SKIP=1` を設定する**

既存のテストステップを次の形へ変更する。

```yaml
      - name: テストを実行する
        env:
          CTS_NO_SKIP: "1"
        run: bash test/run.sh
```

これにより、依存環境不足によるスキップをCIの成功へ含めない。bash 3.2の独立ジョブとDockerの明示的失敗条件は変更しない。

- [ ] **Step 6: CI変更のYAML差分を確認してコミットする**

Run:

```bash
git diff --check
git diff -- .github/workflows/test.yml
git add .github/workflows/test.yml
git commit -m "Issue #11: CIのシェル検査とスキップ防止を追加する"
```

Expected: workflowの変更だけがコミットされ、`git diff --check` が成功する。

### Task 2: READMEと移行・互換性コメントを実態へ合わせる

**Files:**
- Modify: `README.md:36-42,294-300`
- Modify: `install.sh:116-126`
- Modify: `scripts/lib/common.sh:177-181`
- Modify: `test/bash32-e2e.sh:14-23`
- Modify: `test/test-install.sh:1030-1052`
- Modify: `test/test-uninstall.sh:867-890`

**Interfaces:**
- Consumes: `install.sh`のバックアップ条件、管理対象シンボリックリンク拒否、`cts_resolve_path`、bash 3.2 E2Eの実行イメージ、chmod 444テスト
- Produces: 実装の保証範囲・制約・環境を過大に主張しない説明

- [ ] **Step 1: READMEの導入手順とテストランナー説明を修正する**

導入手順のsettings説明を、「既存の `settings.local.json` をこのツールが初めて書き換える場合、既存の `.cts-backup` が無ければ書き換え前の内容を退避する。新規作成時は既存内容のバックアップ対象がない」と読める文へ置き換える。

テストランナー説明には、現在のゲートが検出する対象を列挙したうえで、「ゲートはテストの構造と実行経路を検査するが、各アサーションの意味やテストの十分性を証明するものではない」と追記する。また、`CTS_NO_SKIP=1` はCIで設定してスキップを失敗扱いにする設定であり、ローカル既定値とは別であることを明記する。

- [ ] **Step 2: install.shの旧パス移行コメントを処理条件に合わせる**

「シンボリックリンクは常にリンク自体が移る」と読める断定を改め、管理対象ディレクトリを包むコンテナシンボリックリンクは事前に拒否され、旧パスの個別エントリを `mv` する処理ではリンクを実体化せず移す、という2つの条件を分けて説明する。

- [ ] **Step 3: common.shのパス解決コメントをシンボリックリンクに限定する**

`cts_resolve_path` はシンボリックリンクを段階的に解決して物理的な絶対パスを返す関数であることを記述し、ハードリンクを含む全種類のリンクを辿るように読める表現を使わない。macOSに `realpath` / `readlink -f` がないため自前解決している説明は残す。

- [ ] **Step 4: bash 3.2 E2Eコメントのイメージ説明を修正する**

`test/bash32-e2e.sh` の `bash:3.2` をDebianベースとする記述を、Alpine/muslベースのイメージでありpython3を含まないため、python3を必要とするinstall/uninstallをこのE2Eでは実行しない、という説明へ修正する。テスト対象がhandoff-checkのみであることは維持する。

- [ ] **Step 5: chmod 444テストへroot環境の注意を追加する**

`test/test-uninstall.sh` の旧台帳テストと `test/test-install.sh` の読み取り専用settingsテストで `chmod 444` を行う直前に、root実行時は所有者権限により書き込み・置換が成功し得るため、通常ユーザーと同じモード拒否の検証にならない旨を注記する。テストのロジックや終了条件は変更しない。

- [ ] **Step 6: handoff上限の記述を変更しないことを確認する**

次を確認し、差分を作らない。

```bash
rg -n "8 KB|32 KB|最大 5|8192|32768|CTS_MAX_FILES" \
  skills/session-handoff/SKILL.md scripts/handoff-check.sh
```

Expected: `SKILL.md` と `handoff-check.sh` が1ファイル8KB、合計32KB、最大5ファイルで一致している。

- [ ] **Step 7: ドキュメント差分を確認してコミットする**

Run:

```bash
git diff --check
git diff -- README.md install.sh scripts/lib/common.sh test/bash32-e2e.sh \
  test/test-install.sh test/test-uninstall.sh
git add README.md install.sh scripts/lib/common.sh test/bash32-e2e.sh \
  test/test-install.sh test/test-uninstall.sh
git commit -m "Issue #11: Wave4の説明を実態に合わせる"
```

Expected: 実装コードのロジック変更を含まず、説明・コメントだけがコミットされる。

### Task 3: ローカル検証とCI結果を確認する

**Files:**
- Test: `bash test/run.sh`
- Test: Git管理下の全 `*.sh`
- Verify: `.github/workflows/test.yml`

**Interfaces:**
- Consumes: Task 1のCIゲートとTask 2の説明修正
- Produces: PR作成前の再現可能な検証結果

- [ ] **Step 1: 全テストを実行する**

Run:

```bash
bash test/run.sh
```

Expected: 失敗0件で終了し、実行件数の下限を満たす。スキップが発生した場合は、通常実行の結果として記録し、CI用の `CTS_NO_SKIP=1` 実行と区別する。

- [ ] **Step 2: CIと同じ構文検査を実行する**

Run:

```bash
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(git ls-files -z -- '*.sh')
```

Expected: 全ファイルで終了コード0になる。

- [ ] **Step 3: ShellCheckをCIと同じ対象へ実行する**

Run:

```bash
shellcheck --version
git ls-files -z -- '*.sh' | xargs -0 shellcheck --shell=bash
```

Expected: ShellCheckが利用できる環境では非ゼロ終了がなく、警告を隠すための無根拠な除外がない。ローカル環境にShellCheckが無い場合は、CIへプッシュして同じコマンドの結果を取得するまで成功を主張しない。

- [ ] **Step 4: 差分と作業ツリーを確認する**

Run:

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -4
```

Expected: 未コミット変更がなく、ブランチが `issue-11-wave4-docs-ci` で、Wave 4の設計・CI・説明修正のコミットだけが先頭にある。

### Task 4: 独立レビュー、修正、PR作成を行う

**Files:**
- Review: Issue #11の全差分とCI定義
- Update: レビューで実際に指摘されたファイルだけ

**Interfaces:**
- Consumes: Task 3までのコミットと検証結果
- Produces: CIが成功し、独立レビュー済みのPR

- [ ] **Step 1: サブエージェントへ敵対的レビューを依頼する**

次の観点を明示して、実装担当ではないサブエージェントにレビューを依頼する。

```text
Issue #11のWave4差分を敵対的にレビューしてください。
1. README・コメントが現行実装より強い保証を主張していないか。
2. CTS_NO_SKIP=1 が通常CIのテスト実行へ実際に適用されるか。
3. bash -n がGit管理下の全シェルスクリプトをファイル単位で検査するか。
4. ShellCheckの対象漏れ、失敗を成功扱いにする経路、無根拠な除外がないか。
5. ランタイム挙動やテストロジックを意図せず変更していないか。
重大度をCritical/Major/Minorで示し、指摘なしの場合も理由付きで明記してください。
```

- [ ] **Step 2: 指摘ごとに根拠を確認して修正する**

レビュー指摘がある場合は、対象ファイルの現行コードとテスト結果を照合し、妥当なものだけを最小差分で修正する。修正後はTask 3の全検証を再実行し、同じ観点で再レビューを依頼する。

- [ ] **Step 3: CIを実行して結果を確認する**

ブランチをpushしてGitHub Actionsの通常ジョブとbash32ジョブを確認する。通常ジョブでは、ShellCheck導入、ShellCheck、ファイル単位の `bash -n`、`CTS_NO_SKIP=1` のテストがすべて成功し、bash32ジョブはDockerの明示的な実行結果を返すことを確認する。

- [ ] **Step 4: Issue #11を参照するPRを作成する**

```bash
gh pr create --base main --head issue-11-wave4-docs-ci \
  --title "Issue #11: 波4の記述整合とCI検査を追加する" \
  --body "Issue #11を解決する。設計書、CIのスキップ防止・bash -n・ShellCheck、説明とコメントの整合を含む。検証結果と独立レビュー結果を記載する。"
```

PR本文には、実行したテスト、CI結果、独立レビューでの指摘と修正結果を日本語で記録する。PRがマージ可能になったらユーザーへマージを依頼し、エージェント自身はマージしない。
