# Issue #31 Clock Rollback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `token-report.sh --out` のfreshness判定からwall-clockとmtime依存を除き、今回の計測器だけが生成した検証済みレポートを利用者指定パスへ原子的に配置する。

**Architecture:** 明示 `--out` の最終パスを計測器へ直接渡さず、同じ親ディレクトリのprivate tempへ引数だけを書き換える。計測器終了コード、非空、形式、calibration snapshotを検証した後だけ `mv` で最終パスを置換し、失敗時はlauncherのtempだけを片付ける。既定出力の既存atomic配置は変更しない。

**Tech Stack:** Bash 3.2互換shell、Python fixture、POSIX filesystem操作、既存shell test runner。

## Global Constraints

- 実装はユーザー指定のLuna maxタスクレーンで行い、Sol primaryが実diffとテスト証跡を最終受入する。
- 基点は `origin/main` の `e1391bd6257fe63e62a01bee2ab6d4f46ec7e18d`、作業branchは `issue-31-clock-rollback` とする。
- Issue #30のSessionStart、install/uninstall、hook、台帳ファイルは変更しない。
- `--out VALUE`、`--out=VALUE`、他の引数順序、計測器終了コード、成功メッセージ、既定出力契約を維持する。
- parent directoryを自動作成しない。既存の最終出力は全失敗経路でbyte-for-byte保持する。
- テストを先に追加して現行実装がclock rollbackでREDになることを確認する。
- 通常チェックアウトの未追跡Stage 4文書には触れない。

---

## Task 1: clock rollbackを再現するRED testを固定する

**Files:**
- Modify: `test/test-token-report-launcher.sh`
- Modify: `test/expected-min-count`

- [x] 1. fixture engineの `report` modeで、`CTS_REPORT_MTIME=rollback` のとき書き込み後に `os.utime(out_path, (1, 1))` を実行する。これは内容生成後のmtimeだけを確実に過去へ戻す。
- [x] 2. `test_clock_rollback後のexplicit_outでも今回レポートを採用する` を追加する。既存の最終パスへold canaryを置き、rollback modeでnew canaryを生成し、終了0、最終パスがnew canary、成功出力が利用者指定パスであることを検証する。
- [x] 3. `bash test/run.sh token-report-launcher` を実行し、現行の `-nt` freshness判定による「更新されていません」でこの新規testだけがREDになることを確認する。
- [x] 4. RED testの内容がmtimeを直接検査せず、利用者可視の終了コードと成果物内容を検査していることを確認する。
- [x] 5. この時点ではproduction codeを変更せず、RED testを次Taskの実装と同一commitに含める。

## Task 2: explicit outを同一directory private tempへ差し替える

**Files:**
- Modify: `scripts/token-report.sh`
- Modify: `test/test-token-report-launcher.sh`
- Modify: `test/expected-min-count`

- [x] 1. `test_explicit_outはengineへ最終パスでなくprivate_tempを渡す` を `--out VALUE` 形式で追加し、engine argsのoutが最終パスと異なること、親directoryが同じこと、成功後だけ最終パスへnew canaryがあることを検証する。
- [x] 2. `test_out_equalsもengineへprivate_tempを渡す` を `--out=VALUE` 形式で追加し、他の引数が欠落・並べ替えされないこともengine logで検証する。
- [x] 3. focused testを再実行し、private temp期待の2ケースが現行実装でREDになることを確認する。
- [x] 4. `scripts/token-report.sh` で元の `"$@"` をBash 3.2互換arrayへ複製し、`--out` の次値または `--out=...` だけをlauncherが作ったtemp pathへ置換する。欠損した `--out` 値は従来どおりengine側の公開挙動へ渡し、launcher独自の別エラーへ変えない。
- [x] 5. 明示outでは解決済み最終pathのparent directoryが既存かを確認し、無ければ作成せず終了1にする。最終パスがsymlinkなら参照先を開かず終了1にする。
- [x] 6. 同じparentへ `mktemp "$parent/.token-report.XXXXXX"` でprivate tempを作り、`tmp_out` に記録する。engineへ差し替え後のarrayを渡し、既定出力の既存引数追加経路はそのままにする。呼出元subdirectoryからのrelative `--out` もrepo root基準へ解決する。
- [x] 7. engine成功後はprivate tempを既存の非空・先頭40行 `## 計測条件`・calibration snapshot検査へ渡す。marker作成と明示outの `[ report -nt marker ]` 判定を完全に削除し、mtimeをfreshness根拠に残さない。
- [x] 8. 全検証成功後だけ解決済み最終pathへ `mv` を行う。成功時に `tmp_out` を空にしてtrapが最終成果物を消さないようにし、`report_path` をfinal pathへ更新する。
- [x] 9. 5つの新規成功系testをGREENにし、既存21件もPASSすることを確認した。`test/expected-min-count` を総数572、`test-token-report-launcher.sh 26` に更新する。
- [x] 10. `git diff --check` と対象diffを確認した。commitはTask 4の最終検証後に作成する。

## Task 3: すべての失敗経路で既存出力を保護する

**Files:**
- Modify: `test/test-token-report-launcher.sh`
- Modify: `scripts/token-report.sh`
- Modify: `test/expected-min-count`

- [x] 1. 既存 `test_前回の既存レポートだけで成功扱いにしない` を未来mtimeのold canaryへ強化し、touchless engine後も同じbytesであることを検証する。期待理由はmtimeの「更新」ではなく「今回のprivate tempが空」である。
- [x] 2. 既存のengine非ゼロ、空report、calibration snapshot missing/symlink/stale testへ、明示outにold canaryを置いた場合も内容を保持するassertionを追加する。新規関数数は増やさず既存安全契約を強める。
- [x] 3. `test_symlinkのexplicit_outを拒否し参照先を変更しない` を追加する。linkとtarget内容の両方を検査する。
- [x] 4. `test_explicit_outの最終mv失敗でも既存出力を保持する` を追加する。fixtureのfailing `mv` wrapperを用い、old canary、非ゼロ、temp残存なしを検査する。
- [x] 5. 既存parent missing testを、parent未作成と最終path未作成に加え、engineが起動されていないことまで検証する。
- [x] 6. `bash test/run.sh token-report-launcher` を実行し、新しいsymlink/mvケースのREDを確認してからproduction codeを最小修正した。symlink判定はtemp作成前、mv失敗時はtrapでprivate tempだけ削除する。
- [x] 7. focused testを全件GREENにし、`test/expected-min-count` を総数572、`test-token-report-launcher.sh 26` に更新する。
- [x] 8. `git diff --check` と対象diffを確認した。commitはTask 4の最終検証後に作成する。

## Task 4: 関連回帰と互換性を検証する

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-issue-31-clock-rollback-design.md`
- Inspect: `scripts/token-report.sh`
- Inspect: `test/test-token-report-launcher.sh`

- [x] 1. `bash test/run.sh token-report-launcher`、`token-report`、`calibration`、`token-report-docs`を個別実行し、関連全件PASSを確認した。
- [x] 2. `bash -n scripts/token-report.sh test/test-token-report-launcher.sh`を実行した。
- [x] 3. `bash test/run.sh python-compatibility`を実行し、Python 3.6/3.8互換test 2件をPASSさせた。
- [x] 4. Bash 3.2実体は探索したが環境に無かったため実行不可。GNU Bash 5.2とBash 3.2静的監査（guarded array expansion）を確認した。
- [x] 5. `CTS_NO_SKIP=1 bash test/run.sh`を実行し、総572件・失敗0件・スキップ0件を確認した。
- [x] 6. `rg -n -- '-nt|marker|更新されていません' scripts/token-report.sh test/test-token-report-launcher.sh`が無出力で、report freshnessにmtime/marker判定が残っていないことを確認した。snapshotのinode同一性検査は維持した。
- [x] 7. 設計書の状態を「実装・検証済み」へ更新し、private temp名、repo-root基準の引数置換、rollback再現、失敗時保持の最終契約を反映した。
- [ ] 8. `git status --short`、`git diff origin/main...HEAD --stat`、`git diff origin/main...HEAD`、`git diff --check origin/main...HEAD` をSol primaryへ提示できる形で保存する。
- [ ] 9. 文書更新を `git commit -m "docs: clock rollback修正の検証結果を反映"` でコミットする。

## Task 5: Luna引き渡しとPR境界

- [ ] 1. Lunaはbranchへ必要なcommitを作成するが、pushやPR作成はSol primaryの明示承認まで行わない。
- [ ] 2. Sol primaryは実diff、全commit、focused/full test出力、通常checkout非変更を独立確認する。不備は同じLuna taskへ具体的に返し、修正後に再確認する。
- [ ] 3. 受入後だけLunaへpushとIssue #31をcloseする独立PRの作成を許可する。PR本文へ根本原因、mtime非依存方式、failure atomicity、テスト結果を日本語で記載する。
- [ ] 4. PR作成後はmergeせず、URLと最終check結果をユーザーへ提示してmerge依頼で停止する。
