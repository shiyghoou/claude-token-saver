# 段階4: キャリブレーションと診断 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** 対象プロジェクトのトランスクリプトからセッション切り閾値を中央値で算出し、実測・概算を分離した診断を提示し、ユーザーの明示承認後だけ設定へ適用する。

**Architecture:** 既存の `scripts/measure-token-usage.py` を唯一のトランスクリプト集計基盤として拡張する。Wave 1は読み取り専用の計測・診断と機械可読なスナップショット、Wave 2は独立した安全な適用コマンドとStopフックの軽量な促し状態、Wave 3は導入導線・文書・統合検証を担当する。設定更新は専用Python updaterへ分離し、通常の計測とStopフックからは実行しない。

**Tech Stack:** Python 3.6互換の標準ライブラリ、Bash 3.2互換シェル、依存ゼロの `awk`、既存のBashテストランナー、GitHub Actions。

## Global Constraints

- Issue #24の番号付きブランチで作業し、`main`へ直接編集しない。
- Wave 1〜3を個別PRにし、各PRは独立レビュー完了後にユーザーへマージを依頼する。エージェントはマージしない。
- Python 3.6/3.8互換を維持し、外部Pythonパッケージ、`jq`、ネットワーク、Stopフック内のPython実行へ依存しない。
- Stopフックの入力・状態判定・ロック失敗は、既存契約どおり無出力・標準エラー空・終了コード0で終了する。
- サンプル不足、`cache_read`の有効サンプルなし、中央値0の場合は推奨・促し・適用を行わない。
- 実測値と概算値を別セクションに出力し、概算値を実測合計・中央値・未使用MCP判定へ混ぜない。
- ユーザーが明示的に適用コマンドを実行するまで `.claude/token-saver.json`を変更しない。
- `.claude/token-saver.json`、`.token-saver/calibration/`、状態ファイル、テンポラリファイルのsymlinkを追従しない。
- レポートとスナップショットにprompt本文、tool input、tool result本文、環境変数、認証情報、repo外の実パスを出力しない。
- 画像トークンは未計測であることを明記し、数値を推定して実測として扱わない。
- 既存の`token-report`、`suggest-session-cut`、`session-handoff`の状態・出力・設定項目を壊さない。

---

## ファイル構成と責務

### Wave 1: 計測コアと読み取り専用レポート

- Modify: `scripts/measure-token-usage.py`
  - セッション別usage、assistantターン、tool result、`/compact`、MCP診断、中央値、設定判定、Markdown、`latest.json`を担当する。
- Modify: `scripts/token-report.sh`
  - `--calibrate`実行時のスナップショット成果物検査を担当する。
- Create: `test/test-calibration.sh`
  - 複数セッション、外れ値、診断、秘匿境界、設定閾値をCLI fixtureで検証する。
- Modify: `test/test-token-report-launcher.sh`
  - `--calibrate`引数伝播とスナップショット成果物検査を検証する。
- Modify: `test/test-python-compatibility.sh`, `test/python-compatibility.py`
  - 新しいPythonエンジン境界とCLIをPython 3.6互換スモークへ追加する。
- Modify: `test/expected-min-count`
  - 追加テスト件数の下限を更新する。

### Wave 2: 明示適用と一度だけの促し

- Create: `scripts/apply-token-calibration.py`
  - `latest.json`と現在設定を検証し、閾値と適用メタデータだけを原子的に更新する。
- Create: `scripts/token-calibrate.sh`
  - 導入先rootを解決し、`--apply`以外を拒否してupdaterを起動する。
- Create: `scripts/lib/token-calibrate-entrypoint.sh`
  - install/uninstallが同じ内容を生成する導入先entrypointを担当する。
- Modify: `scripts/lib/paths.sh`
  - `.token-saver/token-calibrate.sh`とキャリブレーション状態のパスを単一定義する。
- Modify: `lib/ledger.py`
  - `token_calibrate_source`の台帳値を安全に読み書きする。
- Modify: `install.sh`, `uninstall.sh`
  - token-calibrate entrypointの所有権、冪等性、削除条件を既存token-reportと同じ契約で扱う。
- Create: `scripts/lib/calibration-config.awk`
  - root直下`calibration`の閾値をJSON全体検証付きで読む。
- Create: `scripts/lib/calibration-state.sh`
  - Bash 3.2で共有するsession ledger、ロック、prompted/applied key、原子的更新を担当する。
- Modify: `scripts/lib/suggest-session-cut-usage.awk`
  - 既存の累積値出力を維持しつつ、要求時だけassistantターン数を併せて出力する。
- Modify: `scripts/suggest-session-cut.sh`
  - 現在セッションの軽量集計を共有ledgerへ反映し、条件達成時だけ短い案内を出す。
- Modify: `scripts/measure-token-usage.py`
  - レポート実行時に共有ledgerを同期し、Stopフックと一度だけ判定を共有する。
- Create: `test/test-token-calibrate.sh`
  - updaterの適用、拒否、保持、symlink、競合スナップショットを検証する。
- Create: `test/test-calibration-hook.sh`
  - Stopフックのサンプル条件、重複抑止、状態破損、symlink、Python不在を検証する。
- Modify: `test/test-suggest-session-cut.sh`, `test/test-suggest-session-cut-docs.sh`
  - 既存セッション切り提案との共存と導線を検証する。
- Modify: `test/test-install.sh`, `test/test-uninstall.sh`
  - 新entrypointの設置・差し替え保護・所有物だけの削除を検証する。

### Wave 3: 文書・統合検証

- Modify: `README.md`
  - 状態表、calibrate操作、明示適用、実測/概算境界、未計測画像を更新する。
- Modify: `skills/token-report/SKILL.md`
  - 読み取り専用レポート、`--calibrate`、`token-calibrate.sh --apply`の使い方を更新する。
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
  - 段階4実装済みの状態、実装導線、既定値と適用契約を反映する。
- Modify: `test/test-token-report-docs.sh`, `test/test-suggest-session-cut-docs.sh`, `test/test-workflow.sh`
  - 旧「calibrate未実装」文言と新コマンドの不一致を検出する。
- Modify: `test/bash32-e2e.sh`
  - Bash 3.2相当環境で既存hookと新しい促しが共存することを検証する。

---

## Wave 1: 計測コアと読み取り専用レポート

### Task 1: セッション別usageと中央値の基礎を追加する

**Files:**
- Modify: `scripts/measure-token-usage.py:211-386`
- Create: `test/test-calibration.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- `SessionStats.cache_read: int` は重複排除後のメインassistant usageの累積値を保持する。
- `SessionStats.assistant_turns: int` は重複排除後のassistant usage行数を保持する。
- `Scan.session_stats: dict` はsessionIdをキーにした`SessionStats`の統計を保持する。
- `median_integer(values)` は空または非正値だけの入力に対して`None`、奇数個では中央値、偶数個では中央2値の整数平均切り捨てを返す。

- [ ] **Step 1: CLIに依存しない中央値・session統計の失敗fixtureを書く**

`test/test-calibration.sh`に、既存の`test/lib/assert.sh`と同じfixture形式で、sessionごとの`cache_read`が`[10, 20, 30, 40, 1000]`になるJSONLを生成する。Task 1ではまだCLIを実装しないため、テストは`runpy.run_path`でエンジンの関数を呼び出す。次のテスト関数とPython harnessを置く。

```bash
test_外れ値を中央値から除外する() {
  output="$(_run_python_harness median 10 20 30 40 1000)"
  assert_eq "30" "$output" "中央値"
}

test_偶数サンプルは中央二値の整数平均を切り捨てる() {
  output="$(_run_python_harness median 10 20 40 1000)"
  assert_eq "30" "$output" "偶数中央値"
}

test_sessionIdが無いusageをサンプル数へ入れない() {
  _fixture_with_missing_session_id
  output="$(_run_python_harness session_count "$FIXTURE_TRANSCRIPT")"
  assert_eq "0" "$output" "不明sessionの除外"
}

_run_python_harness() {
  mode="$1"
  shift
  python3 - "$REPO_ROOT/scripts/measure-token-usage.py" "$mode" "$@" <<'PYEOF'
import runpy
import sys

engine_path, mode = sys.argv[1:3]
module = runpy.run_path(engine_path)
if mode == "median":
    values = [int(value) for value in sys.argv[3:]]
    print(module["median_integer"](values))
elif mode == "session_count":
    scan = module["scan_transcripts"]([sys.argv[3]], None)
    print(len(scan.session_stats))
else:
    raise SystemExit("unknown harness mode")
PYEOF
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh calibration`

Expected: `median_integer`未定義または`Scan.session_stats`未実装でFAILする。CLIの未実装はこのTaskの失敗理由にしない。

- [ ] **Step 3: 最小のセッション統計と中央値を実装する**

`Scan.__init__`へ`session_stats`を追加し、assistant usageを重複排除して`scan.main`へ加える箇所で、空でない`sessionId`だけを対象に`cache_read`とassistantターンを加算する。`message.id`が無い行は既存のfallback keyをそのまま再利用する。次の形で中央値関数を実装する。

```python
def median_integer(values):
    ordered = sorted(value for value in values if isinstance(value, int) and value > 0)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2
```

- [ ] **Step 4: 対象テストを再実行する**

Run: `bash test/run.sh calibration`

Expected: Task 1の中央値・sessionIdテストがPASSし、CLI未実装のまま既存token-reportテストもPASSする。

- [ ] **Step 5: Task 1をコミットする**

```bash
git add scripts/measure-token-usage.py test/test-calibration.sh test/expected-min-count
git commit -m "feat: 段階4のセッション統計と中央値を追加"
```

### Task 2: 判定条件、推奨閾値、スナップショットを追加する

**Files:**
- Modify: `scripts/measure-token-usage.py:1-20,252-386,632-776,821-870`
- Modify: `test/test-calibration.sh`
- Modify: `test/test-token-report-launcher.sh`

**Interfaces:**
- `load_calibration_settings(config_path)` は`{"min_sessions": int, "min_assistant_turns": int}`を返し、不正値は既定値へ戻す。
- `build_calibration(scan, args, since, main_paths, sub_paths)` は`eligible`, `session_count`, `assistant_turns`, `baseline_cache_read`, `current_initial`, `current_increment`, `fingerprint`, `source`を含む辞書を返す。
- `write_calibration_snapshot(snapshot)` は`.token-saver/calibration/latest.json`へJSONを原子的に配置する。
- CLI `--calibrate` は通常レポートへキャリブレーション節を追加し、`latest.json`を生成する。設定ファイルの閾値は変更しない。

- [ ] **Step 1: 不足・設定上書き・自動変更なしを検証する失敗テストを書く**

次のケースを`test/test-calibration.sh`へ追加する。

```bash
test_既定の5セッション100ターン未満は促さない() {
  _fixture_with_turns 4 99
  _run_calibrate
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "判定: **サンプル不足**" "不足判定"
  assert_not_contains "$report" "推奨段階1単位" "不足時の推奨抑止"
}

test_設定で必要数を変更できる() {
  _fixture_with_config 2 3
  _run_calibrate
  assert_contains "$(cat "$FIXTURE_REPORT")" "判定: **算出可能**" "設定閾値"
}

test_calibrateはtoken_saver_configを書き換えない() {
  _fixture_with_eligible_data
  before="$(cat "$FIXTURE_REPO/.claude/token-saver.json")"
  _run_calibrate
  assert_eq "$before" "$(cat "$FIXTURE_REPO/.claude/token-saver.json")" "自動適用禁止"
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh calibration`

Expected: 条件判定、設定上書き、スナップショットのいずれかが未実装でFAILする。

- [ ] **Step 3: 設定とスキャン識別情報を実装する**

`read_json(project_path(".claude", "token-saver.json"))`からroot直下`calibration`だけを読み、正の整数かつ`1 <= value <= 1000000`の値だけ採用する。`initial_cache_read`と`increment_cache_read`は既存のroot直下`suggest_session_cut`から読み、無い場合はともに`30000000`とする。スキャン識別情報は、選択期間、判定条件、各入力JSONLのサイズ・更新時刻をSHA-256へ投入して作る。

`build_calibration`は、条件を満たし中央値が正の場合だけ`eligible=True`とし、段階1を`B`、段階2以降を`B * 2`, `B * 3`として作る。snapshotへは数値、日付、対象期間、サンプル数、assistantターン数、現在値、推奨値、source文字列、scan fingerprintだけを保存する。

- [ ] **Step 4: Markdown節と原子的snapshot保存を実装する**

`build_report`へ`## キャリブレーション`を追加し、サンプル不足時は不足条件だけを表示する。`--calibrate`時は`.token-saver/calibration`を作成し、同一ディレクトリの一時ファイルから`os.replace`で`latest.json`を配置する。既存設定はこの処理で開くだけにし、書き換えない。

- [ ] **Step 5: launcherの成果物検査を追加する**

`scripts/token-report.sh`は`--calibrate`をengineへそのまま渡し、成功後に`$REPO_ROOT/.token-saver/calibration/latest.json`が通常ファイル・非空・今回のレポートと同じ生成時点であることを検査する。symlink、未生成、空、engine非0は既存のreport配置を残さず失敗させる。

- [ ] **Step 6: テストを再実行する**

Run: `bash test/run.sh calibration`

Run: `bash test/run.sh token-report-launcher`

Expected: 条件判定、config非変更、snapshot、launcher引数伝播がPASSする。

- [ ] **Step 7: Task 2をコミットする**

```bash
git add scripts/measure-token-usage.py scripts/token-report.sh test/test-calibration.sh test/test-token-report-launcher.sh
git commit -m "feat: キャリブレーション判定とsnapshotを追加"
```

### Task 3: 実測・概算診断を追加する

**Files:**
- Modify: `scripts/measure-token-usage.py:252-386,501-573,632-776`
- Modify: `test/test-calibration.sh`

**Interfaces:**
- `build_diagnostics(scan, calibration, main_paths, sub_paths)` は`measured`と`estimated`を別々に含む辞書を返す。
- `Scan.main_tool_results` は本文を保持せず、tool名、session、timestamp、payload byte数、対応usageの有無だけを保持する。
- `Scan.compact_events` は発生時点、直前基準、直後値、回復ターン数を計算できる最小情報だけを保持する。
- `classify_unused_mcp(configured, used)` は`unused`, `used`, `unknown`を返し、対応が曖昧なサーバを`unused`へ入れない。

- [ ] **Step 1: 診断fixtureと秘匿境界テストを書く**

`test/test-calibration.sh`のfixtureへ、推奨単位の2倍を超えるsession、mainの大きな`tool_result`、有効設定の`unused_server`・利用済み`used_server`・対応不能な`unknown_server`、`Agent`の起動と`toolUseResult.totalTokens`、`/compact`前後のassistant usage、prompt・tool result本文・MCP引数・外部パスの秘密文字列を追加する。

```bash
test_実測診断と概算診断を分離する() {
  _fixture_with_diagnostics
  _run_calibrate
  report="$(cat "$FIXTURE_REPORT")"
  assert_contains "$report" "## 実測診断" "実測節"
  assert_contains "$report" "## 概算診断" "概算節"
  assert_contains "$report" "未使用MCP" "MCP診断"
  assert_contains "$report" "画像入力のトークン消費は未計測" "画像境界"
  assert_not_contains "$report" "秘密のtool result本文" "本文秘匿"
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh calibration`

Expected: 診断セクションまたは項目が未出力でFAILする。

- [ ] **Step 3: main tool resultと`/compact`の要約だけを収集する**

トランスクリプト走査時に、本文を出力用構造体へ保存せず、JSON serialized byte数とtool名・sessionId・timestampだけを記録する。`/compact`はuser messageの文字列またはtext blockが完全一致する場合だけ数え、直前3 assistant usageの中央値を基準にする。次のassistant usageが基準の90%以上へ戻った最初のターンを回復点とし、無ければ`未回復`とする。

- [ ] **Step 4: MCP、Agent、超過session、概算を集計する**

既存の`mcp_summary`, `mcp_tool_prefixes`, `scan_mcp_tool_names`, Agent usageを再利用する。設定から名前と定義JSONのbyte数だけを読む。設定名とtool prefixを正規化して一意に対応付けられない場合は`unknown`へ入れる。超過sessionは推奨段階2相当以上を対象にし、メインusage合計に対する`cache_read`割合を出す。概算は定義byte数を4で割った推定値として別表へ出し、実測合計へ加えない。

- [ ] **Step 5: Markdownへ出力する**

`build_report`へ実測診断・概算診断の表と、画像未計測の明示を追加する。表示するのは件数、名称、日時、session識別子の安全な短縮値、サイズ、比率だけとし、本文・入力・認証形状の値を`markdown_cell`へ渡さない。

- [ ] **Step 6: テストを再実行する**

Run: `bash test/run.sh calibration`

Expected: 超過session、heavy tool result、unused/used/unknown MCP、Agent比率、`/compact`、概算分離、画像未計測、秘匿境界がPASSする。

- [ ] **Step 7: Task 3をコミットする**

```bash
git add scripts/measure-token-usage.py test/test-calibration.sh
git commit -m "feat: キャリブレーション診断を実測と概算に分離"
```

### Task 4: Wave 1の互換性と独立レビューを完了する

**Files:**
- Modify: `test/python-compatibility.py`, `test/test-python-compatibility.sh`
- Modify: `test/test-token-report-launcher.sh`, `test/expected-min-count`

- [ ] **Step 0: Wave 1の番号付きブランチを作成する**

設計書・計画書を保持した現在のIssue #24ブランチから、Wave 1用ブランチを作成する。

```bash
git switch -c issue-24-wave1-calibration-core
```

- [ ] **Step 1: Python 3.6境界テストを先に追加する**

`test/python-compatibility.py`で`compile()`対象へ`scripts/measure-token-usage.py`を追加し、fixtureを一時ディレクトリへ作って`python3 -B scripts/measure-token-usage.py --calibrate --days 0 --out report.md`を実行する。`__pycache__`、外部依存、秘密本文の出力が無いことを検証する。

- [ ] **Step 2: Wave 1のテストを実行する**

```bash
bash test/run.sh calibration
bash test/run.sh token-report
bash test/run.sh token-report-launcher
bash test/test-python-compatibility.sh
bash test/bash32-e2e.sh
git diff --check
```

Expected: 全コマンドが0で終了し、既存テストの件数下限も満たす。

- [ ] **Step 3: 実装者以外のサブエージェントへWave 1の敵対的レビューを依頼する**

Descartesへ、次の観点でdiffとテスト結果を渡す。

- 外れ値・重複usage・sessionId欠落の誤カウント
- report実行による設定変更やsnapshot symlink追従
- 実測/概算の混入、unused MCPの誤判定
- Python 3.6と既存token-report回帰
- secret本文・tool input・外部パスの漏えい

- [ ] **Step 4: 指摘を修正し、同じレビュー観点で再レビューする**

指摘があれば対象テストを先に追加して修正し、Wave 1の全コマンドと独立再レビューを繰り返す。未解決の指摘が0件になったことをPR説明へ記録する。

- [ ] **Step 5: Wave 1をコミットし、PRを作成する**

```bash
git status --short --branch
git diff --check
git push -u origin issue-24-wave1-calibration-core
gh pr create --base main --head issue-24-wave1-calibration-core \
  --title "feat: 段階4 Wave 1の計測・診断を実装" \
  --body "Issue #24のWave 1です。読み取り専用のキャリブレーション、実測/概算診断、中央値、snapshotを追加しました。テスト結果と独立レビュー結果を記載しています。"
```

PRはユーザーへマージを依頼し、エージェントはマージしない。ユーザーがマージしたら`main`を更新し、Wave 1ブランチをローカル・リモートから削除してからWave 2へ進む。

---

## Wave 2: 明示適用と一度だけの促し

### Task 5: 明示適用用の安全なupdaterを追加する

**Files:**
- Create: `scripts/apply-token-calibration.py`
- Create: `scripts/token-calibrate.sh`
- Create: `test/test-token-calibrate.sh`
- Use: `lib/ledger.py`の`write_atomic`（既存契約を変更しない）

**Interfaces:**
- `load_snapshot(path)` は有効な`latest.json`だけを返し、型・eligible・baseline・fingerprintを検証する。
- `validate_current_config(config, snapshot)` はsnapshotのcurrent値、判定条件、対象識別情報と一致しない場合に拒否する。
- `apply_snapshot(config_path, snapshot)` は`initial_cache_read`、`increment_cache_read`、`calibration.last_applied`だけを変更したJSONを返す。
- `token-calibrate.sh --apply`は成功時0、引数不正64、snapshot/config不正1で終了する。

- [ ] **Step 1: 適用前に失敗するテストを書く**

`test/test-token-calibrate.sh`へ次を追加する。

```bash
test_apply指定が無ければ設定を変更しない() {
  _fixture_with_latest
  before="$(cat "$CONFIG")"
  _run_calibrate_command
  assert_ne "0" "$STATUS" "apply無しの拒否"
  assert_eq "$before" "$(cat "$CONFIG")" "apply無しの非変更"
}

test_適用は閾値以外のキーを保持する() {
  _fixture_with_latest
  _run_calibrate_command --apply
  assert_eq "18000000" "$(_config_value initial_cache_read)" "initial更新"
  assert_eq "18000000" "$(_config_value increment_cache_read)" "increment更新"
  assert_contains "$(cat "$CONFIG")" '"unrelated": "keep"' "未知キー保持"
}

test_現在設定がsnapshotと違えば拒否する() {
  _fixture_with_latest
  _set_initial 123
  _run_calibrate_command --apply
  assert_ne "0" "$STATUS" "競合拒否"
  assert_eq "123" "$(_config_value initial_cache_read)" "競合時非変更"
}

test_設定とsnapshotのsymlinkを追従しない() {
  _fixture_with_latest
  ln -s "$OUTSIDE_CONFIG" "$CONFIG"
  _run_calibrate_command --apply
  assert_ne "0" "$STATUS" "config symlink拒否"
  assert_eq "$OUTSIDE_BEFORE" "$(cat "$OUTSIDE_CONFIG")" "外部非変更"
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh token-calibrate`

Expected: updater未実装、apply無し、競合、symlink保護のテストがFAILする。

- [ ] **Step 3: `apply-token-calibration.py`を実装する**

`lib/ledger.py`の`write_atomic`と同じsymlink拒否・親ディレクトリ検証・一時ファイルからの置換を使用する。configが存在しない場合は既定の`suggest_session_cut`閾値を現在値として扱い、`.claude`が通常ディレクトリでなければ作成・更新しない。JSON rootがobjectでない、`suggest_session_cut`がobjectでない、閾値が正整数でない場合は拒否する。成功時は既存キーを保持したまま、閾値と`calibration.last_applied`へsnapshotのsource、generated_at、sample_count、assistant_turns、previous/recommendedを追加する。

- [ ] **Step 4: `token-calibrate.sh`を実装する**

既存`token-report.sh`と同じtarget root解決を使い、`--apply`を1回だけ受け付ける。`--days`などの未知引数、引数無し、`--apply`の重複は終了コード64で拒否する。engineの通常計測やStopフックを呼ばず、`apply-token-calibration.py --root "$REPO_ROOT" --latest "$REPO_ROOT/.token-saver/calibration/latest.json"`だけを起動する。

- [ ] **Step 5: テストを再実行する**

Run: `bash test/run.sh token-calibrate`

Expected: 明示apply、未知キー保持、current値競合、破損snapshot、設定root、symlink、原子更新がPASSする。

- [ ] **Step 6: Task 5をコミットする**

```bash
git add scripts/apply-token-calibration.py scripts/token-calibrate.sh test/test-token-calibrate.sh
git commit -m "feat: 承認済みキャリブレーションを安全に適用"
```

### Task 6: token-calibrateの導入・削除導線を追加する

**Files:**
- Create: `scripts/lib/token-calibrate-entrypoint.sh`
- Modify: `scripts/lib/paths.sh`
- Modify: `lib/ledger.py`
- Modify: `install.sh`, `uninstall.sh`
- Modify: `test/test-install.sh`, `test/test-uninstall.sh`, `test/test-python-compatibility.sh`

**Interfaces:**
- `cts_token_calibrate_rel()` は`.token-saver/token-calibrate.sh`を返す。
- `cts_write_token_calibrate_entrypoint(output, source_launcher)` はinstall/uninstallでbyte-identicalなentrypointを生成する。
- ledger key `token_calibrate_source` はsource launcherの絶対パスだけを記録する。

- [ ] **Step 1: entrypoint所有権テストを追加する**

install fixtureへ、導入後に`$TARGET/.token-saver/token-calibrate.sh`が実行可能で、source cloneのlauncherを呼び、再installで1つだけ残るケースを追加する。既存ファイル・symlink・内容差し替え時は警告して残すケースを追加する。uninstall fixtureへ、台帳記録がある自前entrypointだけを削除し、差し替えられたentrypointは残すケースを追加する。

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh install`

Run: `bash test/run.sh uninstall`

Expected: 新entrypointのテストが、path関数・生成関数・install/uninstall未実装でFAILする。

- [ ] **Step 3: path、entrypoint、ledgerを実装する**

`paths.sh`へパスを1箇所だけ追加し、entrypoint生成関数はtoken-report版と同じくsource cloneのlauncherを`CTS_TOKEN_CALIBRATE_TARGET_ROOT`付きで呼ぶ。`ledger.py`の`has_record(any)`へ`token_calibrate_source`を加え、set/get valueの許可名へ追加する。既存のtoken-report記録と壊れた台帳の扱いは変更しない。

- [ ] **Step 4: install/uninstallを実装する**

installは`apply-token-calibration.py`、`token-calibrate.sh`、`measure-token-usage.py`が揃う場合だけentrypointを設置し、既存物のsymlink・非通常ファイル・内容差し替えを触らない。設置後に`token_calibrate_source`を台帳へ原子的に記録する。uninstallは台帳記録と生成内容が一致するときだけ削除し、token-reportの削除判定や共有設定の扱いを変更しない。

- [ ] **Step 5: テストを再実行する**

Run: `bash test/run.sh install`

Run: `bash test/run.sh uninstall`

Run: `bash test/test-python-compatibility.sh`

Expected: 新旧entrypoint、冪等性、差し替え保護、台帳、Python互換がPASSする。

- [ ] **Step 6: Task 6をコミットする**

```bash
git add scripts/lib/paths.sh scripts/lib/token-calibrate-entrypoint.sh lib/ledger.py install.sh uninstall.sh test/test-install.sh test/test-uninstall.sh test/test-python-compatibility.sh
git commit -m "feat: token-calibrateの導入導線を追加"
```

### Task 7: Stopフックの軽量ledgerと一度だけの促しを追加する

**Files:**
- Create: `scripts/lib/calibration-config.awk`
- Create: `scripts/lib/calibration-state.sh`
- Modify: `scripts/lib/suggest-session-cut-usage.awk`
- Modify: `scripts/suggest-session-cut.sh`
- Create: `test/test-calibration-hook.sh`
- Modify: `test/test-suggest-session-cut.sh`, `test/expected-min-count`

**Interfaces:**
- `cts_calibration_config_number(config, key)` は完全JSON検証後にroot直下`calibration.<key>`の正整数を返し、無効時は非0を返す。
- `cts_calibration_record_session(root, session_key, cache_read, assistant_turns, min_sessions, min_turns)` は共有ledgerを更新し、促す場合だけ`CTS_CALIBRATION_PROMPT=1`を返す。
- `suggest-session-cut-usage.awk -v summary=1` は`cache_read<TAB>assistant_turns`を出力し、既定モードの既存単一数値出力を変えない。

- [ ] **Step 1: hookの失敗・再実行・競合テストを書く**

`test/test-calibration-hook.sh`へ、5 session/100 turns未満は無出力、条件達成時は案内1回、同じ`session_count:turn_count:min_sessions:min_turns` keyでは2回目無出力、ledger symlink・state lock失敗・不正payloadでは既存Stop hookと同じrc0/stderr空、並行実行では案内1回だけ、を追加する。案内には次の2コマンドを含める。

```text
./.token-saver/token-report.sh --calibrate
./.token-saver/token-calibrate.sh --apply
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh calibration-hook`

Expected: 新しいhookテストが、設定parser・state ledger・session turn summary未実装でFAILする。

- [ ] **Step 3: config AWKとsummary出力を実装する**

既存`config.awk`の完全JSONパーサ構造を複製せず共通可能な範囲で合わせ、新しいparserは`calibration`以外の値を出力しない。`summary=1`時だけ、既存のmessage.id/fallback keyで重複排除したassistant usage件数を2列目へ出す。JSON構文、末尾文字、文字列中の偽キー、負数、小数、root違いを拒否する。

- [ ] **Step 4:共有stateを実装する**

`.token-saver/calibration/sessions.tsv`は`numeric_session_key<TAB>cache_read<TAB>assistant_turns<TAB>last_seen`だけを持ち、`.token-saver/calibration/state`は`prompted_key`と`applied_key`だけを持つ。`mkdir "$state_dir/.lock"`でロックし、既存ファイル・親ディレクトリ・一時ファイルがsymlinkなら無出力で抜ける。更新は同一ディレクトリの一時ファイルからrenameし、keyは数値と`-`だけに制限する。

- [ ] **Step 5:既存Stop hookへ統合する**

既存のセッション切り提案用state lockを保持したまま、summary結果をcalibration stateへ反映する。キャリブレーションの案内は既存の切り提案を置き換えず、既存提案が出る場合は同じstdoutへ別行として追加する。calibration側の失敗は既存提案のrc・stderr・出力を変更しない。

- [ ] **Step 6:テストを再実行する**

Run: `bash test/run.sh calibration-hook`

Run: `bash test/run.sh suggest-session-cut`

Expected: 一度だけの案内、既存の境界・状態・symlink・競合・fail-closedテストがPASSする。

- [ ] **Step 7:Task 7をコミットする**

```bash
git add scripts/lib/calibration-config.awk scripts/lib/calibration-state.sh scripts/lib/suggest-session-cut-usage.awk scripts/suggest-session-cut.sh test/test-calibration-hook.sh test/test-suggest-session-cut.sh test/expected-min-count
git commit -m "feat: Stopフックへキャリブレーション促しを追加"
```

### Task 8: token-reportとStopフックの促し状態を同期する

**Files:**
- Modify: `scripts/measure-token-usage.py`
- Modify: `scripts/token-report.sh`
- Modify: `test/test-calibration.sh`, `test/test-calibration-hook.sh`, `test/test-token-report-launcher.sh`

**Interfaces:**
- `sync_calibration_state(root, session_stats, min_sessions, min_turns, source_key)` は、Python reportからshellと同じ`sessions.tsv`/`state`形式へ同期する。
- `calibration_prompt_key(session_count, assistant_turns, min_sessions, min_turns)` はshellと同じ文字列を返す。
- `build_calibration(scan, args, since, main_paths, sub_paths)`は`prompt_available`を返し、通常reportでは短い案内、`--calibrate`では根拠付き案内を出す。

- [ ] **Step 1: report/hook重複を検出するテストを書く**

次の順序をfixtureへ追加する。

1. `token-report.sh`を2回実行し、案内が合計1回であること。
2. Stop hookを先に実行し、`token-report.sh --calibrate`後の案内が0回であること。
3. `token-report.sh --calibrate`を先に実行し、Stop hook後の案内が0回であること。
4. 新しいsessionを追加した場合だけprompt keyが変わり、次の周期の案内が1回出ること。

- [ ] **Step 2:失敗を確認する**

Run: `bash test/run.sh calibration`

Run: `bash test/run.sh calibration-hook`

Expected: reportとhookが別々に案内を出すためFAILする。

- [ ] **Step 3: Python側のstate同期を実装する**

Python側は`session_stats`をkey順にTSV化し、同一lock directoryを取得してから既存session行を置換する。条件未達、正のcache_read中央値なし、状態更新失敗時はsnapshot/reportの数値を壊さず、promptを出さない。reportは設定JSONの閾値を絶対に変更しない。

- [ ] **Step 4:適用後の周期識別を実装する**

`apply-token-calibration.py`は`latest.json`のprompt keyを`applied_key`へ記録する。report/hookは現在keyが`prompted_key`または`applied_key`と同じ場合は再促しせず、session数またはassistantターン数が増えて新しいkeyになった場合だけ促す。

- [ ] **Step 5:テストを再実行する**

Run: `bash test/run.sh calibration`

Run: `bash test/run.sh calibration-hook`

Run: `bash test/run.sh token-calibrate`

Expected: report/hook/applyのstate共有、一度だけ、次周期、config非変更がPASSする。

- [ ] **Step 6:Task 8をコミットする**

```bash
git add scripts/measure-token-usage.py scripts/token-report.sh test/test-calibration.sh test/test-calibration-hook.sh test/test-token-report-launcher.sh
git commit -m "feat: 計測とStopフックの促し状態を同期"
```

### Task 9: Wave 2の全検証と独立レビューを完了する

- [ ] **Step 1: Wave 2の対象テストを実行する**

```bash
bash test/run.sh calibration
bash test/run.sh calibration-hook
bash test/run.sh token-calibrate
bash test/run.sh suggest-session-cut
bash test/run.sh install
bash test/run.sh uninstall
bash test/test-python-compatibility.sh
bash test/bash32-e2e.sh
git diff --check
```

- [ ] **Step 2: Descartesへ敵対的レビューを依頼する**

レビュー観点は、config symlink・latest snapshot競合・state lock競合・ledger境界、明示apply前の非変更、hook fail-closed、report/hookの二重促し、既存session-cut回帰とする。

- [ ] **Step 3: 指摘を修正し、独立再レビューを完了する**

指摘ごとに再現テストを追加して修正し、Wave 2の全検証を再実行する。レビュー結果が0件になるまで繰り返す。

- [ ] **Step 4: Wave 2をPR化してユーザーへマージを依頼する**

```bash
git status --short --branch
git diff --check
git push -u origin issue-24-wave2-calibration-apply
gh pr create --base main --head issue-24-wave2-calibration-apply \
  --title "feat: 段階4 Wave 2の明示適用と促しを実装" \
  --body "Issue #24のWave 2です。明示承認による設定適用、導入先entrypoint、Stopフックとの一度だけの促しを追加しました。テスト結果と独立レビュー結果を記載しています。"
```

ユーザーのマージ後にmainを最新化し、Wave 2のローカル・リモートブランチを削除してからWave 3へ進む。

---

## Wave 3: 文書・統合検証

### Task 10: README・Skill・主設計書を実装状態へ更新する

**Files:**
- Modify: `README.md`
- Modify: `skills/token-report/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `test/test-token-report-docs.sh`, `test/test-suggest-session-cut-docs.sh`, `test/test-workflow.sh`

- [ ] **Step 1: 旧未実装文言を検出する現行契約を確認する**

Run: `bash test/run.sh token-report-docs`

Run: `bash test/run.sh suggest-session-cut-docs`

Expected: 現在の「calibrateは未実装（段階4）」契約がPASSし、実装状態へ更新した後に反転させる対象を確認する。

- [ ] **Step 2: READMEを更新する**

状態表を`キャリブレーションと診断（calibrate） | **実装済み**`へ更新し、次の導線を記載する。

```text
./.token-saver/token-report.sh --calibrate
./.token-saver/token-calibrate.sh --apply
```

サンプル不足、中央値、明示適用、設定非変更、実測/概算の分離、unused MCPの判定不能、画像未計測を同じ節で説明する。

- [ ] **Step 3: Skillと主設計書を更新する**

`skills/token-report/SKILL.md`から「calibrate未実装」を削除し、通常reportと`--calibrate`の違い、snapshot、applyの明示承認を記載する。主設計書の状態表・§5.5・機能連動・テスト契約へ段階4の実装結果と詳細設計書へのリンクを追加する。段階5の未実装状態は残す。

- [ ] **Step 4: 文書契約テストを更新する**

旧文言の`assert_not_contains`を新しい実装状態のassertへ変更し、両コマンド、測定/概算、画像未計測、config非変更、Issue #24の導線を検証する。文書中のコードブロックと実装のコマンド名を一致させる。

- [ ] **Step 5:テストを再実行する**

Run: `bash test/run.sh token-report-docs`

Run: `bash test/run.sh suggest-session-cut-docs`

Run: `bash test/run.sh workflow`

Expected: 旧未実装文言がなく、新導線・段階5の未実装表示・Issue/branch契約がPASSする。

- [ ] **Step 6:Task 10をコミットする**

```bash
git add README.md skills/token-report/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md test/test-token-report-docs.sh test/test-suggest-session-cut-docs.sh test/test-workflow.sh
git commit -m "docs: 段階4の利用方法と実装状態を反映"
```

### Task 11: Wave 3の全テスト、敵対的レビュー、PRを完了する

- [ ] **Step 1:全テストを実行する**

```bash
bash test/run.sh
bash test/bash32-e2e.sh
bash test/test-python-compatibility.sh
git diff --check
git status --short --branch
```

Expected: `test/run.sh`の総件数・ファイル別下限を満たし、全テスト0、bash32 E2E 0、Python互換0、作業ツリーは意図したコミットのみになる。

- [ ] **Step 2: Descartesへ最終敵対的レビューを依頼する**

Wave 1/2で確認した実装契約に加え、README・SKILL・主設計書・installer/uninstallerの導線不一致、Stage3機能の退行、実測/概算の混入、ユーザー設定の無断変更を確認する。

- [ ] **Step 3:指摘を修正して再レビューする**

レビュー指摘に対応する回帰テストを追加し、全テスト、bash32 E2E、Python互換を再実行する。未解決指摘を残したままPRをマージ可能とは扱わない。

- [ ] **Step 4: Wave 3をPR化してユーザーへマージを依頼する**

```bash
git status --short --branch
git diff --check
git push -u origin issue-24-wave3-calibration-docs
gh pr create --base main --head issue-24-wave3-calibration-docs \
  --title "docs: 段階4の導線と統合検証を完了" \
  --body "Issue #24のWave 3です。README、token-report skill、主設計書、文書/統合テストを更新しました。全テストと独立レビュー結果を記載しています。"
```

ユーザーがマージした後、mainのマージ状態を確認し、ローカル・リモートのWave 3ブランチを削除する。最後に`gh issue view 24`でIssue #24の状態を確認し、残課題がなければユーザーへ完了報告する。

## 完了判定

- Issue #24の全受入条件をテスト結果へ対応付けられる。
- サンプル不足時に促し・推奨・適用が起きない。
- 外れ値を含むデータで中央値が平均へ退行しない。
- `token-report`、Stopフック、`token-calibrate --apply`のどの経路も、明示適用以外でユーザー設定を変更しない。
- unused MCPの判定不能を未使用と誤分類しない。
- 実測と概算、画像未計測をレポート上で区別できる。
- Stage3のセッション切り提案、session-handoff、install/uninstall、既存の全テストが退行しない。
- 各Waveで独立した敵対的レビューが完了し、指摘修正後の再レビューが0件になる。
- 各WaveのPRはユーザーがマージし、エージェントはマージしていない。
