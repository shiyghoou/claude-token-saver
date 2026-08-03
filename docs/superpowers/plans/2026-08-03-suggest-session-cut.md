# Suggest session cut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Issue #23の段階3として、累積`cache_read`が閾値へ到達したときだけセッション切りを提案する、汎用的で失敗時にセッション終了を妨げないStopフックを導入する。

**Architecture:** `scripts/suggest-session-cut.sh`がStopフックの入力・対象root・設定・状態を扱い、`scripts/lib/suggest-session-cut-usage.awk`がトランスクリプトJSONLを読み取り、assistant usageの重複を除いて`cache_read_input_tokens`を合計する。状態は導入先の`.token-saver/suggest-session-cut/`に置き、セッション別cache/markerを原子的に更新し、期限切れ状態を掃除する。既存の`install.sh`の「実体のあるStopフックだけ登録」経路を段階3の成果物として有効化する。

**Tech Stack:** Bash 3.2互換シェル、POSIX awk、既存の`test/run.sh`、ShellCheck。

## Global Constraints

- Issue #23の`issue-23-suggest-session-cut`ブランチだけで作業し、`main`へ直接編集しない。
- 閾値の既定値は初回30,000,000、増分30,000,000とする。到達判定は累積値が初回閾値以上である場合に`floor((total-initial)/increment)+1`番目の境界へ達したものとする。
- 設定ファイルは導入先`.claude/token-saver.json`の次の形を正とする。`suggest_session_cut.initial_cache_read`、`suggest_session_cut.increment_cache_read`、`suggest_session_cut.retention_days`、`suggest_session_cut.log_max_bytes`、`suggest_session_cut.log_backups`は正の整数（`log_backups`のみ0を許可）である。無効値は既定値へ倒す。
- 環境変数は設定ファイルより優先し、`CTS_SESSION_CUT_INITIAL_CACHE_READ`、`CTS_SESSION_CUT_INCREMENT_CACHE_READ`、`CTS_SESSION_CUT_RETENTION_DAYS`、`CTS_SESSION_CUT_LOG_MAX_BYTES`、`CTS_SESSION_CUT_LOG_BACKUPS`を使う。
- `.git/`へ状態を書かない。git worktree（`.git`がファイル）と非gitディレクトリの両方で、状態は導入先rootの`.token-saver/`下へ置く。
- Stopフックは`/clear`を実行しない。提案文にはユーザーが引き継ぎを書いてから手動で切ることを明示する。
- 入力、トランスクリプト、設定、状態が判定不能または書き込み不能な場合は提案せず、標準エラーを汚さず、終了コード0で終える。状態を書けないのに提案だけを出して同じ閾値を繰り返さない。
- Bash 3.2で動く構文だけを使う。連想配列、`mapfile`、Bash 4専用配列展開、`jq`、`timeout`、Pythonへの実行時依存を追加しない。
- 変更コードを先に書かず、各タスクで失敗するテストを先に追加してREDを確認する。テストはfixture内だけへ書き、リポジトリ本体を汚染しない。
- 警告・ログへtranscript本文、セッションID、絶対パス、設定値以外の利用者テキストを出さない。提案標準出力は固定文と数値だけにする。
- レビューで指摘されたログローテーション、セッション別marker/cacheの掃除、cacheのtmp→rename原子書き込みを実装し、回帰テストで守る。
- マージはユーザーが行う。エージェントはPR作成までに留める。

## File Structure

| ファイル | 役割 | 変更 |
|---|---|---|
| `scripts/suggest-session-cut.sh` | Stopフック本体、入力・設定・状態・提案 | 新規 |
| `scripts/lib/suggest-session-cut-usage.awk` | JSONLのusage抽出、message.id等の重複排除、合計 | 新規 |
| `scripts/lib/suggest-session-cut-config.awk` | 設定JSONの安全な数値フィールド抽出 | 新規 |
| `scripts/lib/paths.sh` | suggest-session-cut状態相対パスの単一情報源 | 変更 |
| `test/test-suggest-session-cut.sh` | 閾値、入力、状態、ローテーション、掃除、worktree/non-git fixture | 新規 |
| `test/test-suggest-session-cut-docs.sh` | README/SKILL/spec/installer導線の一致検査 | 新規 |
| `test/test-paths.sh` | 新しい状態パスの契約 | 変更 |
| `test/test-install.sh` | Stopフック登録の実体・往復 | 変更 |
| `test/test-uninstall.sh` | Stopフック除去の往復 | 変更 |
| `test/expected-min-count` | テスト件数下限 | 変更 |
| `README.md` | 段階3の状態、使い方、既定値の限界、設定 | 変更 |
| `skills/session-handoff/SKILL.md` | 切り提案を受けたときの引き継ぎ手順と設定の案内 | 変更 |
| `docs/specs/2026-07-31-claude-token-saver-design.md` | 実装済み段階3と§5.3の実装契約 | 変更 |
| `docs/superpowers/plans/2026-08-03-suggest-session-cut.md` | 本計画 | 新規 |

---

### Task 1: Stopフック本体とJSONL集計を実装する

**Files:**
- Create: `scripts/suggest-session-cut.sh`
- Create: `scripts/lib/suggest-session-cut-usage.awk`
- Create: `scripts/lib/suggest-session-cut-config.awk`
- Modify: `scripts/lib/paths.sh`
- Modify: `test/test-paths.sh`
- Create: `test/test-suggest-session-cut.sh`

**Interfaces:**
- Consumes: Stop hook JSONの`cwd`、`session_id`、`transcript_path`、assistant message usage。
- Produces: 閾値到達時だけ固定の日本語提案をstdoutへ出し、常にrc=0で終了する。状態は`cts_session_cut_rel()`配下の`<hash>.cache`、`<hash>.marker`、`events.log`へ置く。

- [ ] **Step 1: fixtureと契約テストを追加する**

  最低限、次を独立したテスト関数として固定する。

  - 29,999,999では無出力、30,000,000で1回だけ提案、同じStop再実行では重複提案しない。
  - 60,000,000で次の境界を提案する。複数境界を一度に越えた場合も1回だけ出し、markerを最新境界へ進める。
  - `message.id`が同じassistant行、id無しで`requestId`とusageが同じ行を重複集計しない。文字列本文中の同名キーは集計しない。
  - `transcript_path`、`session_id`、`cwd`の欠落・壊れたJSON・読めないJSONL・読めないファイルでは誤発火せず、stdout/stderrが空でrc=0になる。
  - configの初回閾値/増分と環境変数上書き、環境変数優先、無効値の既定値フォールバックを検証する。
  - `.git`が無いroot、`.git`がファイルのworktree、空白を含むrootで同じ状態パスを使う。`.git/`配下にファイルを作らない。
  - ログ上限を小さくしたときの`.1`ローテーション、古いsession cache/markerの期限掃除、cache更新後に一時ファイルを残さないことを検証する。
  - `/clear`や`clear`という操作を呼ばず、既存handoff/token-reportへ状態を混ぜないことを検証する。

- [ ] **Step 2: 不在実装でREDを確認する**

  ```bash
  CTS_MIN_TESTS=0 bash test/run.sh suggest-session-cut
  ```

  Expected: 対象スクリプト不在で非0。テストが無実行の緑にならないことも確認する。

- [ ] **Step 3: Bash 3.2互換の実装を追加する**

  JSONLはawkの字句解析でキーと数値を認識し、JSON文字列中の似た文字列を拾わない。assistant messageの`message.id`を第一キー、id無しは`requestId`・timestamp・usage値の代替キーとして重複排除する。Stopフックは入力を読み切れない場合もfail-closedとし、本体をサブシェルで実行して親から無条件にrc=0を返す。

  設定値を検証後、累積値と境界番号を比較する。提案前にcacheとmarkerを同一ディレクトリ内の一時ファイルへ書いてrenameし、ログは上限を超える前に世代交代する。期限切れのcache/marker/tempを限定された状態ディレクトリから除去する。

- [ ] **Step 4: focused testをGREENにする**

  ```bash
  CTS_MIN_TESTS=0 bash test/run.sh suggest-session-cut
  bash -n scripts/suggest-session-cut.sh
  ```

  Expected: fixture全件成功、hookのstdout/stderr契約と状態副作用が確認できる。

- [ ] **Step 5: Task 1をコミットする**

  ```bash
  git add scripts/lib/paths.sh scripts/lib/suggest-session-cut-*.awk scripts/suggest-session-cut.sh test/test-paths.sh test/test-suggest-session-cut.sh
  git commit -m "feat: Stopフックでセッション切りを提案する"
  ```

### Task 2: install/uninstallと利用者向け導線を同期する

**Files:**
- Modify: `test/test-install.sh`
- Modify: `test/test-uninstall.sh`
- Create: `test/test-suggest-session-cut-docs.sh`
- Modify: `test/expected-min-count`
- Modify: `README.md`
- Modify: `skills/session-handoff/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`

**Interfaces:**
- Consumes: Task 1の`script`、`cts_session_cut_rel()`、既存`settings-hooks.py`台帳経路。
- Produces: `install.sh`再実行で実体のあるStopフックだけが1件登録され、`uninstall.sh`でその登録が外れる。README/SKILL/specが同じ設定名・既定値・限界を示す。

- [ ] **Step 1: 導入・文書のRED検査を追加する**

  Stopフック登録/除去の台帳往復、READMEの状態表、SKILLの設定例、設計書§5.3と実装フェーズ表の一致を検証する。既存のユーザーフックを保持すること、再実行でStop登録が重複しないことも含める。

- [ ] **Step 2: 必要な導線を更新する**

  READMEでは段階3を実装済みへ変更し、既定値が移植元の条件付き実測であること、config/envの正確なキー、状態パス、提案後の手動操作を案内する。`skills/session-handoff/SKILL.md`では提案を受けたら引き継ぎを書いてユーザーへ切断を提案する手順を同期する。設計書の棚卸し、§5.3、実装フェーズ、テスト記録を実装内容へ合わせる。

- [ ] **Step 3: install/uninstall、docs、全体テストをGREENにする**

  ```bash
  bash test/run.sh suggest-session-cut
  bash test/run.sh install
  bash test/run.sh uninstall
  CTS_NO_SKIP=1 bash test/run.sh
  ```

  Expected: Stopフックが実体のある場合だけ登録され、往復で利用者の独自設定を失わず、文書の数値・パス・操作が一致する。テスト件数台帳は実測値へ更新する。

- [ ] **Step 4: Task 2をコミットする**

  ```bash
  git add README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md test/test-install.sh test/test-uninstall.sh test/test-suggest-session-cut-docs.sh test/expected-min-count
  git commit -m "docs: 段階3のセッション切り提案を案内する"
  ```

---

## Review and Completion

- [ ] 各タスクで別のサブエージェントによる仕様準拠・品質レビューを行い、Critical/Importantは修正して再レビューする。
- [ ] ブランチ全体を別の最も強いレビュアーで敵対的レビューし、テスト未検証の契約、状態競合、パス逸脱、Bash 3.2回帰を確認する。
- [ ] `git diff --check`、focused test、全体テスト、ShellCheck、Bash 3.2 e2e相当の検証結果を記録する。
- [ ] PR本文・レビュー結果・コミットメッセージは日本語で作成し、Issue #23をリンクする。
- [ ] PR作成後はユーザーへマージを依頼し、エージェントは直接マージしない。
