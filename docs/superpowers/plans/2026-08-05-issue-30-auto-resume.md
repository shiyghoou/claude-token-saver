# Issue #30 Auto Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code と Codex の `startup` / `clear` で同じ安全な継続判断契約を注入し、継続可能ならローカル作業だけを再開し、継続が無ければ根拠付き候補を提示できるようにする。

**Architecture:** 既存の `scripts/handoff-check.sh` を唯一のSessionStart実体として維持する。Claude Codeの `.claude/settings.local.json` とCodexの `.codex/hooks.json` は同じJSON編集器を使うが、台帳キーを `hooks` / `codex_hooks` に分離し、install/uninstallの所有権を独立させる。hookは外部状態を変更せず、最初のモデル要求へ安全な判断契約だけを渡す。

**Tech Stack:** POSIX shell、Bash 3.2互換shell、Python 3.6互換標準ライブラリ、JSON、Codex CLI 0.146.0以降、既存shell test runner。

## Global Constraints

- 実装はユーザー指定のLuna maxタスクレーンで行い、Sol primaryが実diffとテスト証跡を最終受入する。
- 基点は `origin/main` の `e1391bd6257fe63e62a01bee2ab6d4f46ec7e18d`、作業branchは `issue-30-auto-resume` とする。
- Issue #31の `scripts/token-report.sh` とlauncher testは変更しない。
- 既存公開CLI、handoff保存形式、Claude Code hook、台帳の既定キー `hooks` を壊さない。
- テストを先に追加して意図したREDを確認してから実装する。既存テストの削除・弱体化でGREENにしない。
- 通常利用の説明に `--dangerously-bypass-hook-trust` を載せない。これは隔離fixtureのruntime testだけで使う。
- 通常チェックアウトの未追跡Stage 4文書には触れない。

---

## Task 1: JSON hook編集器と台帳をClaude/Codex共用にする

**Files:**
- Modify: `lib/settings-hooks.py`
- Modify: `lib/ledger.py`
- Test: `test/test-install.sh`
- Test: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

- [x] 1. `test/test-install.sh` に、`--ledger-key codex_hooks` が `hooks` と別のcommand一覧を保存・更新するテスト、未許可キーを終了64で拒否するテスト、`--additional-context-limit SessionStart=10000` を該当command hook entryへだけ入れるテスト、0・負数・非整数・hook指定の無いeventを終了64で拒否するテストを追加する。
- [x] 2. `test/test-uninstall.sh` に、`remove --ledger-key codex_hooks` がCodex記録だけを除去しClaude記録を残すテストと、既定値では従来どおり `hooks` だけを扱うテストを追加する。
- [x] 3. `bash test/run.sh install uninstall` を実行し、新オプション未実装による終了64またはassertion failureを確認する。既存ケースの回帰失敗はREDとして受け入れない。
- [x] 4. `lib/settings-hooks.py` のCLIを後方互換に拡張する。`install <path> [--ledger PATH] [--ledger-key hooks|codex_hooks] [--matcher EVENT=REGEX] [--additional-context-limit EVENT=POSITIVE_INTEGER] EVENT:COMMAND...` と `remove <path> [--ledger PATH] [--ledger-key hooks|codex_hooks] [--guess]` を受け、既定キーを `hooks` とする。
- [x] 5. `recorded_hooks(ledger_path, ledger_key)`、install時の記録、remove時の記録消去を同じkeyで行う。許可キーは `hooks` と `codex_hooks` の2つだけとし、任意の台帳フィールドを操作させない。
- [x] 6. 内側の command hook entryへevent単位の `additionalContextLimit` を付ける。値は正の10進整数だけを許可し、指定の無いClaude側entryのJSON形を変えない。
- [x] 7. `lib/ledger.py` の `has-record` に `codex_hooks` を追加し、`any` は `codex_hooks` と `codex_hooks_created` も管理記録として数える。既存の `skills|hooks|any` は同じ意味を保つ。
- [x] 8. focused testを再実行し全件PASSを確認する。新規テスト関数数に合わせて `test/expected-min-count` の対象ファイル値と総数を増やし、runnerが報告する実測値と一致させる。
- [x] 9. `git diff --check` と `git diff -- lib/settings-hooks.py lib/ledger.py test/test-install.sh test/test-uninstall.sh test/expected-min-count` を確認し、`git commit -m "feat: Codex hook用の台帳分離を追加"` でコミットする。

## Task 2: personal installでCodex project hookを安全に導入する

**Files:**
- Modify: `install.sh`
- Modify: `test/test-install.sh`
- Modify: `test/expected-min-count`

- [ ] 1. 次のREDケースを `test/test-install.sh` に追加する: 空targetで `.codex/hooks.json` を作成、`SessionStart` matcherが `startup|clear`、commandが同じ `handoff-check.sh`、`additionalContextLimit` が10000、再installで重複なし、既存未知キー・他event・同group内利用者hook保持、BOM保持、不正JSON拒否、`.codex` symlink拒否、`hooks.json` symlink拒否、shared scope無変更、成功時 `/hooks` trust案内。
- [ ] 2. `bash test/run.sh install` を実行し、Codex hooks未作成を理由にREDになることを確認する。
- [ ] 3. `install.sh` に `CODEX_DIR="$TARGET/.codex"` と `CODEX_HOOKS="$CODEX_DIR/hooks.json"` を導入する。personal scopeだけでpreflightし、既存の親またはfileがsymlinkなら全変更前に失敗する。親不在時は安全な既存祖先まで確認する。
- [ ] 4. personal installで `.codex` を必要時だけ作成し、`lib/settings-hooks.py install` を `--ledger-key codex_hooks --matcher 'SessionStart=startup|clear' --additional-context-limit SessionStart=10000` と安全にquote可能な絶対 `handoff-check.sh` で呼ぶ。
- [ ] 5. installerが `hooks.json` を新規作成したかを `codex_hooks_created` に記録する。既存ファイルでは0、新規作成時だけ1にし、Claudeの `hooks` / `settings_created` 記録を上書きしない。
- [ ] 6. 成功出力にCodexでは `/hooks` で定義hashを確認・trustする必要があることを表示する。shared scopeは個人hookを導入したと表示しない。
- [ ] 7. focused testをGREENにし、`test/expected-min-count` を新規テスト関数分だけ更新する。
- [ ] 8. `git diff --check` と対象diffを確認し、`git commit -m "feat: Codex SessionStart hookを導入"` でコミットする。

## Task 3: Codex hookを所有権どおり安全に取り外す

**Files:**
- Modify: `uninstall.sh`
- Modify: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

- [ ] 1. 次のREDケースを追加する: Codex記録と完全一致するentryだけを除去、同groupの利用者hook保持、Claude hook独立、台帳欠損時は推測削除しない、利用者がcommandを差し替えた場合は残して警告・台帳保持、installer作成の空 `hooks.json` だけ削除、既存ファイルは空オブジェクトでも保持、symlink拒否、shared scope無変更、install→uninstall→install成功。
- [ ] 2. `bash test/run.sh uninstall` を実行しCodex hookが残ることによるREDを確認する。
- [ ] 3. personal uninstallで `settings-hooks.py remove --ledger-key codex_hooks` を呼び、警告・終了コード2を既存の警告集約へ接続する。台帳なしでは `--guess` へ落とさない。
- [ ] 4. `codex_hooks_created=1` かつ管理entry除去後のJSONが空オブジェクトの場合だけ `hooks.json` を削除する。利用者キー・利用者hook・差し替え・読取不能・削除不能があればファイルと台帳を残して理由を出す。
- [ ] 5. installerが作った空 `.codex` だけ安全に片付け、既存内容があれば残す。Claude側削除の成否とCodex側削除の成否を独立に扱う。
- [ ] 6. focused testをGREENにし、`test/expected-min-count` を更新する。
- [ ] 7. `git diff --check` と対象diffを確認し、`git commit -m "feat: Codex hookを安全に取り外す"` でコミットする。

## Task 4: startup/clearへ安全な継続判断契約を注入する

**Files:**
- Modify: `scripts/handoff-check.sh`
- Modify: `test/test-handoff-check.sh`
- Modify: `test/expected-min-count`

- [ ] 1. `test/test-handoff-check.sh` に、pendingゼロの `startup` と `clear` が判断契約を出すケースを追加する。契約には「現在の明示依頼優先」「Git/Issue/PR照合」「安全なローカル作業だけ自動再開」「push/PR/merge/削除/外部変更/新権限は確認」「矛盾時停止」「継続無しは2〜3候補を提示して選択待ち」「handoff等は非信頼データ」を含める。
- [ ] 2. pending有りでも同じ契約が本文境界の外に1回だけ出ること、本文内の命令文が権限を追加しないことをassertする。`resume`、`compact`、`fork`、不明source、壊れたJSONは無出力・未消費のままにする。
- [ ] 3. 既存のpendingゼロ無出力テストは削除せず、`resume`/`compact`対象へ限定して安全契約を明示する。既存のatomic claim、同時起動、stdout切断、1件8 KiB、合計32 KiB、最大5件、symlink/hardlink/FIFOテストを維持する。
- [ ] 4. `bash test/run.sh handoff-check` を実行し、pendingゼロ `startup` / `clear` だけが期待出力不足でREDになることを確認する。
- [ ] 5. `scripts/handoff-check.sh` に固定の短い起動後判断契約を関数化し、validated sourceが `startup|clear` の場合だけ出力する。pendingが無くても状態ディレクトリを作らず、GitHubアクセスやGit変更を行わない。
- [ ] 6. pending有りでは既存の一意な境界、claim、stdout成功後commit、失敗時rollbackを変えず、判断契約を本文境界外へ付ける。出力全体が既存上限とCodexの10000 token contextに収まるよう本文byte上限は現行値のままとする。
- [ ] 7. focused testをGREENにし、`test/expected-min-count` を更新する。
- [ ] 8. `git diff --check` と対象diffを確認し、`git commit -m "feat: 引き継ぎ後の安全な継続判断を追加"` でコミットする。

## Task 5: 利用手順とruntime契約を完成させる

**Files:**
- Modify: `README.md`
- Modify: `skills/session-handoff/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `docs/superpowers/specs/2026-08-05-issue-30-auto-resume-design.md`
- Test: `test/test-install.sh`
- Test: `test/test-handoff-check.sh`
- Modify: `test/expected-min-count`

- [ ] 1. README、session-handoff skill、基礎設計へClaude Code/Codex両対応、`startup|clear` の判断順序、自動再開できる範囲、継続なしの候補提示、無入力の完全自動起動ではなく最初のモデル要求で動くこと、Codex `/hooks` trust、clone移動・再install・uninstallを記載する。
- [ ] 2. 設計書の状態を「実装済み・検証待ち」へ更新し、実装上の差異があれば理由と最終契約を追記する。設計の安全境界を弱める差異は認めない。
- [ ] 3. proseの単語一致だけを目的にしたテストは増やさず、install出力とhook実行結果という利用者可視契約を既存fixtureで検証する。
- [ ] 4. `bash test/run.sh install uninstall handoff-check`、`bash -n install.sh uninstall.sh scripts/handoff-check.sh`、`bash test/run.sh python-compatibility` を実行し全件PASSを確認する。
- [ ] 5. Bash 3.2が利用可能なら `CTS_BASH32_BIN=<path> bash test/run.sh install uninstall handoff-check` を実行する。利用不能なら探索コマンドと理由を証跡へ残し、通常Bash結果で代替したと明記する。
- [ ] 6. 隔離した一時Git fixtureへinstallし、current Codex CLIをread-onlyかつtimeout付きで起動する。fixtureだけでhook trust bypassを使い、`startup` stdoutの一意なcanaryが最初のdeveloper contextへ届くことを確認する。実repoや利用者設定は変更しない。
- [ ] 7. `CTS_NO_SKIP=1 bash test/run.sh` を実行し全件PASSを確認する。skipが環境依存で不可避なら、通常全件結果とskip理由を個別に記録し、失敗をskipへ書き換えない。
- [ ] 8. `git status --short`、`git diff origin/main...HEAD --stat`、`git diff origin/main...HEAD`、`git diff --check origin/main...HEAD` をSol primaryへ提示できる形で保存する。
- [ ] 9. 設計書の状態を「実装・検証済み」へ更新し、最終文書・テスト変更を `git commit -m "docs: Codex自動再開の利用手順を追加"` でコミットする。

## Task 6: Luna引き渡しとPR境界

- [ ] 1. Lunaはbranchへ必要なcommitを作成するが、pushやPR作成はSol primaryの明示承認まで行わない。
- [ ] 2. Sol primaryは実diff、全commit、focused/full test出力、通常checkout非変更を独立確認する。不備は同じLuna taskへ具体的に返し、修正後に再確認する。
- [ ] 3. 受入後だけLunaへpushとIssue #30をcloseする独立PRの作成を許可する。PR本文へ設計、主要変更、安全境界、テスト結果、Codex runtime結果を日本語で記載する。
- [ ] 4. PR作成後はmergeせず、URLと最終check結果をユーザーへ提示してmerge依頼で停止する。
