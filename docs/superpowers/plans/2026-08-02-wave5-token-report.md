# Wave 5 token-report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PAWARS の実績ある計測器を claude-token-saver のパス・運用・プライバシー境界へ一般化し、任意の導入先で Claude Code の使用量を再現可能な Markdown レポートとして取得できるようにする。

**Architecture:** `scripts/measure-token-usage.py` が JSONL の走査・重複排除・集計・秘匿済み Markdown 生成を担当し、`scripts/token-report.sh` は日時付き出力先の決定と成果物検証だけを担当する。`skills/token-report/SKILL.md` は実行方法と限界を案内し、fixture ベースの Bash テストが engine と launcher の境界を検証する。

**Tech Stack:** Python 3 標準ライブラリ、Bash 3.2 互換のランチャ、依存ゼロの Bash テストランナー `test/run.sh`、ShellCheck（CI）。

## Global Constraints

- Issue #13 の `issue-13-wave5-token-report` ブランチだけで作業し、`main` を直接編集しない。
- `scripts/measure-token-usage.py` は標準 Python ライブラリだけを使い、実データ・設定・既存レポートを読み取り専用として扱う。
- メインセッションの `message.id` 重複、id 無し行の代替キー、サブエージェントの `totalTokens` を契約どおりに扱い、本文・prompt・tool result content・秘密値を出力しない。
- `CLAUDE_CONFIG_DIR` が空なら `HOME/.claude` を使い、cwd に対応するプロジェクトを特定できない場合は全件フォールバックを本文と stderr の警告で明示する。
- `scripts/token-report.sh` は Bash 3.2 互換を保ち、既定の `.token-saver/token-reports/` で既存ファイルを上書きしない。
- `skills/token-report/SKILL.md` に PAWARS 固有の Issue、ブランチ、PR、提出先を残さない。
- 実装コードを変更する前に、それを失敗させるテストを追加して実行する。各タスクは RED → GREEN → 検証 → コミットの順で進める。
- テスト実行後に `.pyc`、`__pycache__`、fixture の秘密値、レポート生成物をリポジトリへ残さない。
- マージはユーザーが行う。エージェントは PR 作成までに留める。

---

## File Structure

| ファイル | 役割 | 変更 |
|---|---|---|
| `scripts/measure-token-usage.py` | JSONL走査、usage集計、秘匿済みMarkdown生成 | 新規 |
| `scripts/token-report.sh` | 既定出力先、衝突回避、engine実行結果の検証 | 新規 |
| `skills/token-report/SKILL.md` | 利用者向け実行手順と限界 | 新規 |
| `test/test-token-report.sh` | engineのfixture回帰テスト | 新規 |
| `test/test-token-report-launcher.sh` | launcherの出力・失敗契約 | 新規 |
| `test/test-token-report-docs.sh` | SKILL/READMEの重要な導線とPAWARS固有文の不在 | 新規 |
| `test/expected-min-count` | テストファイル別・総件数の下限 | 変更 |
| `README.md` | token-reportの状態、実行例、保存先、限界 | 変更 |
| `docs/specs/2026-07-31-claude-token-saver-design.md` | §5.2の実装済み範囲と出力先 | 変更 |
| `docs/superpowers/specs/2026-08-02-wave5-token-report-design.md` | 承認済み設計 | 既存、変更しない |

---

### Task 1: engine の fixture 回帰テストを追加して RED にする

**Files:**
- Create: `test/test-token-report.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Produces: `bash test/run.sh token-report` が、合成 `HOME` と `CLAUDE_CONFIG_DIR` の下に作った JSONL を `scripts/measure-token-usage.py` へ渡す契約テスト。
- Consumes: まだ存在しない `scripts/measure-token-usage.py` の CLI（`--days`、`--out`、`--all-projects`、`--paths`）。

- [ ] **Step 1: PAWARS fixture を claude-token-saver 用に移植してテストを書く**

  `/mnt/g/PAWARS/PAWARS/.claude/scripts/test-measure-token-usage.sh` の fixture と検証観点を基に、対象パスだけを `scripts/measure-token-usage.py` へ置き換える。次の具体的な fixture を含める。

  - 同じ `message.id` で thinking/tool_use が別行にある assistant usage。
  - `requestId` と usage が同じ id 無し行を複数行にしたケース。
  - `toolUseResult` の `agentType`、`resolvedModel`、`totalTokens`、`usage`、prompt、content。
  - `session/subagents/a.jsonl` にある、親へ混ぜてはいけない assistant usage。
  - 期間外の古い assistant 行。
  - hook のコマンド、環境変数、MCP env、本文、prompt に秘密の sentinel を入れた設定と JSONL。
  - `mcp__...__...` の実利用、記号差、設定に無いサーバ、無効プラグイン、プラグイン外参照、相対 installPath。
  - repo内・repo外・兄弟・相対 Read パス、壊れた JSONL、`message.content` が list でない行。

  アサーションは少なくとも次の関数名で、レポートの実値と非漏えいを確認する。

  ```bash
  test_同一message_idの重複を一度だけ集計する()
  test_id無し行の重複を代替キーで抑える()
  test_subagentsの詳細usageを親の合計へ混ぜない()
  test_サブエージェントをagentTypeとresolvedModelで分類する()
  test_期間外の行を除外し_days_0で全期間を読む()
  test_本文_prompt_tool結果_env_認証情報を出力しない()
  test_MCP設定と実利用の差分を報告する()
  test_repo外のReadパスを隠す()
  test_CLAUDE_CONFIG_DIRと長い空白入りプロジェクトパスを扱う()
  test_壊れたJSONLとcontent型違いでもトレースバックを出さない()
  test_入力と設定とリポジトリを変更しない()
  ```

- [ ] **Step 2: fixture テストが存在しない engine を失敗させることを確認する**

  Run:

  ```bash
  bash test/run.sh token-report
  ```

  Expected: `scripts/measure-token-usage.py` が無いため、検証対象の存在チェックまたは各実行が失敗し、終了コードは非0になる。engine を先に追加してからテストを書くとこの RED を証明できないため、ここで停止して確認する。

- [ ] **Step 3: テストファイルの下限だけを実測値へ合わせる**

  Run:

  ```bash
  bash test/run.sh token-report
  ```

  Expected: engine 不在による失敗が表示され、テストファイル自体は読み込まれる。出力末尾の `実行件数` を使って `test/expected-min-count` に `test-token-report.sh <実測値>` を追加する。総件数の下限も同じ実測値を加算して更新する。

- [ ] **Step 4: fixture の追加をコミットする**

  ```bash
  git add test/test-token-report.sh test/expected-min-count
  git commit -m "test: Wave5のtoken-report fixtureを追加する"
  ```

---

### Task 2: `measure-token-usage.py` を最小変更で移植する

**Files:**
- Create: `scripts/measure-token-usage.py`
- Test: `test/test-token-report.sh`

**Interfaces:**
- Consumes: Task 1 の `HOME`、`CLAUDE_CONFIG_DIR`、project fixture、CLI引数。
- Produces: `main()`、`project_key()`、`scan_transcripts()`、`build_report()` を中心とした読み取り専用 Markdown 計測器。

- [ ] **Step 1: 参照実装の共通部を移植する**

  `/mnt/g/PAWARS/PAWARS/.claude/scripts/measure-token-usage.py` から次の境界を保ったまま移植する。

  - `CLAUDE_CONFIG_DIR`/`HOME` の解決、`find_project_root()`、Claude Code の project key（UTF-16 code unit、200文字上限、base36 hashを含む）の再現。
  - `parse_ts()`、値の整形・安全化、`Usage` と `Scan` の集計入れ物。
  - `message.id` の全ファイル横断 dedup、id 無し代替キー、期間判定、main/subagents の走査分離。
  - `toolUseResult.totalTokens` の型検査（boolを整数として扱わない）、agentType/resolvedModel/usage の集計。
  - `content_blocks()` の list 型ガード、壊れた JSONL 行の無視、標準エラーへの Traceback 非出力。

  移植後の対象ファイルに `PAWARS`、Issue番号、PAWARS専用のレポート提出先を残さない。レポートに prompt、content、環境変数値、認証情報、コマンド引数を書き込むコードも持ち込まない。

- [ ] **Step 2: engine の RED テストを GREEN にする**

  Run:

  ```bash
  bash test/run.sh token-report
  ```

  Expected: 全 fixture が成功し、少なくとも main 合計 `3,391`、全期間合計 `81,098`、サブエージェント `12,345`、MCP 利用合計 `4回` など、fixture に定義した値がレポートに現れる。秘密 sentinel は一つも現れず、壊れた行でも rc=0・stderrにTracebackなしになる。

- [ ] **Step 3: Python単体の構文・ヘルプを確認する**

  ```bash
  python3 -B scripts/measure-token-usage.py --help
  python3 -B -c 'import ast; ast.parse(open("scripts/measure-token-usage.py", encoding="utf-8").read())'
  ```

  Expected: CLIのヘルプが出て終了コード0、AST解析が終了コード0、リポジトリに `.pyc`/`__pycache__` が増えない。

- [ ] **Step 4: engine の移植をコミットする**

  ```bash
  git add scripts/measure-token-usage.py
  git commit -m "feat: Wave5のtoken-report計測エンジンを追加する"
  ```

---

### Task 3: launcher の衝突回避と成果物検証を追加する

**Files:**
- Create: `scripts/token-report.sh`
- Create: `test/test-token-report-launcher.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: `scripts/measure-token-usage.py`、`.token-saver/token-reports/`、利用者の `--days`/`--out`/`--top`/`--all-projects`/`--paths`。
- Produces: `scripts/token-report.sh [options]`。既定出力は `.token-saver/token-reports/YYYYMMDD-HHMMSS.md`、既存なら `-2` 以降を使う。

- [ ] **Step 1: launcher の失敗テストを先に追加する**

  `test/test-token-report-launcher.sh` に、テンポラリの作業リポジトリと固定時刻の `date` を使った次のケースを追加する。

  ```bash
  test_既定のtoken_reportsへ日時付きレポートを作る()
  test_同じ秒の既存レポートを上書きせず連番にする()
  test_explicit_outを使い親ディレクトリを勝手に作らない()
  test_daysとall_projectsとpathsをengineへ渡す()
  test_計測器が非ゼロならlauncherも非ゼロにする()
  test_成功rcでも空レポートなら失敗にする()
  test_前回の既存レポートだけで成功扱いにしない()
  test_python3が無ければ理由を表示して失敗する()
  ```

  launcher のテストでは実リポジトリの `.token-saver` を使わず、fixture 下のスクリプトコピーを実行する。固定時刻で `YYYYMMDD-HHMMSS` の衝突を再現し、`-L` も存在判定に含める。

- [ ] **Step 2: launcher が存在しない状態で RED を確認する**

  ```bash
  bash test/run.sh token-report-launcher
  ```

  Expected: 対象 `scripts/token-report.sh` 不在で非0になる。

- [ ] **Step 3: Bash 3.2互換の薄い launcher を実装する**

  実装は次の順序に限定する。

  1. `BASH_SOURCE[0]` の位置から `SCRIPT_DIR` とリポジトリルートを解決する。
  2. `--out` の明示有無を値の一致でなくフラグで保持する。
  3. 既定出力時だけ `mkdir -p .token-saver/token-reports` と日時＋連番を使う。明示出力先の親は作らない。
  4. engine を既定 `--out` と利用者引数で呼び、終了コードを確認する。
  5. 出力が非空で、markerより新しく、先頭40行に `計測条件` があることを確認する。
  6. 失敗理由を stderr に出し、トランスクリプトや設定は変更しない。

  `set -uo pipefail` を維持し、連想配列、`mapfile`、Bash 4専用の配列展開を使わない。

- [ ] **Step 4: launcher テストを GREEN にする**

  ```bash
  bash test/run.sh token-report-launcher
  bash -n scripts/token-report.sh
  ```

  Expected: launcher の全ケース成功、構文検査成功、固定時刻の同名レポートが連番で残る。

- [ ] **Step 5: 下限と launcher をコミットする**

  ```bash
  bash test/run.sh token-report
  git add scripts/token-report.sh test/test-token-report-launcher.sh test/expected-min-count
  git commit -m "feat: token-reportの出力ランチャを追加する"
  ```

---

### Task 4: token-report スキルとドキュメント導線を追加する

**Files:**
- Create: `skills/token-report/SKILL.md`
- Create: `test/test-token-report-docs.sh`
- Modify: `README.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: `scripts/token-report.sh` と `scripts/measure-token-usage.py` の確定 CLI。
- Produces: 利用者がスキルを読むだけで安全な計測手順・出力先・限界を理解できる文書。

- [ ] **Step 1: ドキュメントの整合テストを先に追加する**

  `test/test-token-report-docs.sh` は次を実行時に検査する。

  ```bash
  test_token_report_SKILLがlauncherと保存先を案内する()
  test_token_report_SKILLが設定自動変更を指示しない()
  test_READMEがtoken_reportを実装済みと案内する()
  test_設計書の段階2がtoken_reportのCLIと限界を案内する()
  test_PAWARS固有のIssueと提出先を新規文書に残さない()
  ```

  RED の確認として `bash test/run.sh token-report` を実行し、未作成ファイルによる失敗を確認する。`test/expected-min-count` はこの時点の実測件数へ合わせる。

- [ ] **Step 2: `skills/token-report/SKILL.md` を作成する**

  文書には次の内容を実際のコマンドで記載する。

  ```text
  ./scripts/token-report.sh
  ./scripts/token-report.sh --days 30
  ./scripts/token-report.sh --days 0 --all-projects
  ```

  保存先は `.token-saver/token-reports/`、engineのオプション、共有前に本文を含まないこと、cache_read の重みが課金確定値でないこと、MCPと画像の限界、次段階（Stopフック・calibrate）は未実装であることを記載する。計測結果を根拠に設定ファイルを勝手に書き換える指示は置かない。

- [ ] **Step 3: README と基本設計書を更新する**

  README の状態表を「計測（token-report）: 実装済み」へ更新し、導入後の実行例とレポート保存先を追加する。既存の段階3〜5を未実装として残す。READMEの「数値は条件付きの目安」「cache_readの重み」「共有レポートに含めない情報」の記述と engine の出力契約を一致させる。

  `docs/specs/2026-07-31-claude-token-saver-design.md` の §5.2 と実装フェーズ表を、`scripts/measure-token-usage.py`、`scripts/token-report.sh`、`.token-saver/token-reports/` の実態へ合わせる。§5.3以降の未実装範囲は変更しない。

- [ ] **Step 4: ドキュメントテストを GREEN にする**

  ```bash
  bash test/test-token-report-docs.sh
  bash test/run.sh token-report
  git diff --check
  ```

  Expected: launcher・SKILL・README・基本設計書の導線が一致し、`PAWARS`、`Issue #230`、PAWARS固有の提出先が Wave 5 の新規文書・レポート案内に現れない。

- [ ] **Step 5: ドキュメントをコミットする**

  ```bash
  git add skills/token-report/SKILL.md README.md \
    docs/specs/2026-07-31-claude-token-saver-design.md \
    test/test-token-report-docs.sh test/expected-min-count
  git commit -m "docs: token-reportの利用方法と限界を追加する"
  ```

---

### Task 5: Wave 5 の総合検証とミューテーション確認

**Files:**
- Modify: `test/expected-min-count`（実測値が増えた場合のみ）
- Test: `test/test-token-report.sh`
- Test: `test/test-token-report-launcher.sh`
- Test: `test/test-token-report-docs.sh`

**Interfaces:**
- Consumes: Task 1〜4 の全成果物。
- Produces: PRへ記録できる検証結果と、レビューへ渡す固定 SHA 範囲。

- [ ] **Step 1: 対象テストを個別に実行する**

  ```bash
  bash test/run.sh token-report
  bash test/run.sh token-report-launcher
  bash test/run.sh token-report-docs
  ```

  Expected: 各対象に0 failures、0 unexpected skipsがあり、ファイル別下限を満たす。

- [ ] **Step 2: フルスイートと静的検査を実行する**

  ```bash
  bash test/run.sh
  bash -n install.sh uninstall.sh scripts/*.sh test/*.sh
  python3 -B scripts/measure-token-usage.py --help
  git diff --check
  git status --short --branch
  ```

  Expected: フルスイートは失敗0・スキップ0、全shellの構文検査とCLIヘルプは終了コード0、空白エラーなし、作業ツリーには意図した Wave 5 のファイルだけがある。

- [ ] **Step 3: CIと同じShellCheck対象を検査する**

  `shellcheck` が利用可能なら次を実行する。

  ```bash
  shellcheck --shell=bash --severity=error install.sh uninstall.sh scripts/*.sh
  ```

  `shellcheck` が無い場合は未検証の成功を主張せず、GitHub Actions の `test` ジョブで実行する検査としてPR本文に明記する。テストファイルは日本語関数名を含むため、この対象へ追加しない。

- [ ] **Step 4: 代表的なミューテーションで検査感度を確認する**

  リポジトリ本体を変更したままにしない一時コピーで、次の変異を1つずつ適用して対応テストが赤くなることを確認し、コピーを破棄する。

  - engineの `seen_messages` 判定を外す → 重複合計のアサーションが失敗する。
  - `subagents` を main_paths に含める → 親合計の二重計上アサーションが失敗する。
  - `toolUseResult` の prompt/content をレポートへ連結する → sentinel非出力アサーションが失敗する。
  - launcherの衝突回避を外す → 同じ秒の2回目が既存レポートを上書きするアサーションが失敗する。

- [ ] **Step 5: 総合検証をコミットする**

  件数下限の実測値を確認してから、変更がある場合だけ次を実行する。

  ```bash
  git add test/expected-min-count
  git commit -m "test: Wave5の実行件数下限を更新する"
  ```

---

### Task 6: 独立レビュー、修正、PR準備

**Files:**
- Review: `git diff <base-sha>..HEAD`
- Modify: レビューで根拠がある指摘の対象ファイル
- Test: Task 5 の全検証コマンド

- [ ] **Step 1: 実装担当ではないサブエージェントへ敵対的レビューを依頼する**

  次の観点を明示して、Issue #13、設計書、計画書、参照実装との差分を渡す。

  ```text
  Wave 5 token-report を敵対的にレビューしてください。
  重点は、JSONL重複排除の漏れ、subagentsの二重計上、cwd/project keyの誤特定、
  fallbackによる別リポジトリ混入、prompt/content/env/引数の漏えい、Markdown破壊、
  launcherの既存ファイル上書き、Bash 3.2非互換、PAWARS固有文の残留、
  受け入れ条件とテストの不一致です。
  Critical / Important / Minor と、再現コマンドまたは対象行を示してください。
  ```

- [ ] **Step 2: Critical/Importantを修正し、失敗→修正→再検証する**

  各指摘について、まず再現するfixtureまたはテストを追加・修正し、失敗を確認してから実装を直す。修正後は対象テスト、フルスイート、構文検査、ShellCheckを再実行する。レビューが誤りの場合は、fixtureと出力を根拠にPRへ理由を記録する。

- [ ] **Step 3: 最終レビューとPR作成前検証を行う**

  ```bash
  git status --short --branch
  git diff --check
  bash test/run.sh
  bash -n install.sh uninstall.sh scripts/*.sh test/*.sh
  git log --oneline d6ad56c..HEAD
  ```

  Expected: 作業ツリーがクリーン、全件成功、意図したコミットだけがあり、レビュー結果がPR本文またはレビューコメントへ日本語で記録されている。

- [ ] **Step 4: PR作成時の検証内容を記載する**

  PR本文には、Issue #13、計測器・launcher・skill・テスト・文書の変更、読み取り専用と秘匿境界、ローカル検証、CI検証、独立レビュー結果を記載する。エージェントはマージせず、ユーザーへマージを依頼する。
