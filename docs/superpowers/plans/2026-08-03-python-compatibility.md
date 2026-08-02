# Python 3.6 / 3.8 Compatibility Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `lib/*.py` が Python 3.6、3.8、現在の開発環境で実行できることを実機で検証し、対象テストとCIで同じ検証を再実行できる状態にする。互換性問題が見つかった場合は、最小修正と回帰テストを同じIssueの範囲で追加する。

**Architecture:** `lib/` の3本は既存どおり標準ライブラリと同ディレクトリの `ledger` だけに依存させる。Python固有の互換性スモークは `test/python-compatibility.py` に集約し、現在のテストランナーからも1テストとして呼び出す。GitHub Actionsでは現在の開発用ジョブに加え、公式Python Dockerイメージの3.6/3.8を使う独立ジョブを置く。

**Tech Stack:** Python 3.6 / 3.8 / 現行Python、Python標準ライブラリ、Bash、Docker、GitHub Actions。

## Global Constraints

- Issue #17 の範囲だけを扱い、Python 3.6未満とtoken-reportの新機能は対象外とする。
- `lib/*.py` の本番依存に外部パッケージを追加しない。
- `main` は直接編集せず、`issue-17-python-compatibility` ブランチで作業する。
- 既存の `test/run.sh` の件数ゲートと、Python 3.2未満を想定しない既存方針を壊さない。
- コマンド、結果、環境、CIの判定基準は日本語で記録する。

---

## Task 1: 現行コードの互換性ベースラインを固定する

**Files:**
- Inspect: `lib/gitignore-block.py`
- Inspect: `lib/ledger.py`
- Inspect: `lib/settings-hooks.py`
- Inspect: `test/test-install.sh`
- Inspect: `test/test-uninstall.sh`

- [ ] `lib/*.py` の構文を現行Pythonで `python3 -B` と `compile()` により検査する。
- [ ] import一覧と使用APIを確認し、`pathlib`、`typing`、`subprocess`、外部パッケージの使用有無を記録する。
- [ ] 現行Pythonで既存の `test/test-install.sh`、`test/test-uninstall.sh` と全体テストを実行し、変更前の基準値を記録する。
- [ ] Python 3.6/3.8の実行ファイルまたはDockerイメージを確認し、実機検証に使う固定バージョンを決める。

## Task 2: Python対象スモークテストを追加する

**Files:**
- Create: `test/python-compatibility.py`
- Create: `test/test-python-compatibility.sh`
- Modify: `test/expected-min-count`

- [ ] `test/python-compatibility.py` はPython 3.6で解釈できる構文だけで書き、`lib/*.py` 3本をファイルへ `.pyc` を作らずに `compile()` する。
- [ ] 一時ディレクトリ内で `ledger.py` の台帳作成・skill/valueの読み書き・記録判定を実行する。
- [ ] 一時設定と台帳を使って `settings-hooks.py` の matcher付きinstall/removeを実行し、JSONと台帳の結果を検査する。
- [ ] 一時 `.gitignore` を使って `gitignore-block.py` のapply/removeを実行し、マーカーと原状復帰を検査する。
- [ ] `subprocess.run()` はPython 3.6に存在しない `capture_output` / `text` を使わず、3.6互換の引数だけで起動する。
- [ ] Bash側の `test/test-python-compatibility.sh` から現行Pythonを呼び出し、全体テストの件数台帳へ実測値を反映する。

## Task 3: Python 3.6 / 3.8 のCI実機検証を追加する

**Files:**
- Modify: `.github/workflows/test.yml`
- Modify: `test/test-workflow.sh`（workflowの契約検査が必要な場合のみ）

- [ ] `python:3.6.15-slim-buster` と `python:3.8.20-slim-bookworm` を使う独立jobを追加する。
- [ ] 各コンテナへリポジトリを読み取り専用でマウントし、`python -B test/python-compatibility.py` を実行する。
- [ ] イメージ取得・起動失敗をスキップせずCI失敗として扱う。
- [ ] 既存の現行Pythonテストジョブは維持し、3つの環境で同じ対象スモークの成功を確認できるようにする。

## Task 4: 互換性結果とサポート基準を文書化する

**Files:**
- Modify: `README.md`

- [ ] `lib/*.py` の検証対象、標準ライブラリのみの依存、Python 3.6/3.8のCI検証方法を依存節または検証節へ追記する。
- [ ] 実際に使用したPythonバージョン、Dockerイメージ、コマンド、全体テスト結果をIssue/PR本文で再現可能な形に整理する。
- [ ] 検証結果が成功した場合は、確認できた範囲を越えて「Python 3.6未満」や未検証の将来版まで保証しない。

## Task 5: 検証・修正・独立レビュー

- [ ] 現行Pythonで対象スモーク、install/uninstall、全体テスト、`bash -n`、workflow契約テストを実行する。
- [ ] Python 3.6/3.8 Docker実機検証を実行し、失敗時は原因を切り分けて最小修正と回帰テストを追加する。
- [ ] 実装担当とは別のサブエージェントで、受入条件・Python 3.6互換性・CIのスキップ防止・テストの実効性を敵対的にレビューする。
- [ ] 指摘があれば修正後に同じ検証と別担当レビューを繰り返す。
- [ ] 変更を日本語のコミットで記録し、Issue #17を参照するPRを作成する。マージはユーザーへ依頼し、エージェントでは実行しない。

## Verification Commands

```bash
python3 --version
python3 -B test/python-compatibility.py
bash test/test-install.sh
bash test/test-uninstall.sh
CTS_NO_SKIP=1 bash test/run.sh
docker run --rm --mount "type=bind,src=$PWD,dst=/work,readonly" -w /work \
  python:3.6.15-slim-buster python -B test/python-compatibility.py
docker run --rm --mount "type=bind,src=$PWD,dst=/work,readonly" -w /work \
  python:3.8.20-slim-bookworm python -B test/python-compatibility.py
```

作業中に実際のイメージタグが取得できない場合は、同じメジャー・マイナーバージョンの公式Pythonイメージへ切り替え、採用したタグをREADMEとPRへ明記する。
