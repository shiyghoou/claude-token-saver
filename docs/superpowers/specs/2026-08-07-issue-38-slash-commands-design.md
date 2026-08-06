# Issue #38: Claude Code スラッシュコマンド設計

## 1. 目的

ユーザーが手で実行する CLI 機能を、Claude Code のスラッシュコマンド（`.claude/commands/`）からも呼べるようにする。呼び出し入口を増やし、実行ロジックは既存スクリプトへ委譲する薄い層にとどめる。

## 2. 決定（ロック済み）

| 項目 | 決定 |
|---|---|
| `/token-saver:report` | 追加。`./.token-saver/token-report.sh` を実行 |
| `/token-saver:calibrate` | 追加。確認済み snapshot のときだけ `./.token-saver/token-calibrate.sh --apply` |
| `/token-saver:suggest-session-cut` | 追加。Stop フック登録済みの `suggest-session-cut.sh` を手動でも呼べる入口 |
| `measure-token-usage.py` | スラッシュコマンド化しない（token-report 経由で足りる） |
| `delegation-policy` | スラッシュコマンド化しない（スキル側の判断ガイドのまま） |
| 既存スキル | 維持。コマンドは追加の入口でありスキルを置き換えない |
| Codex | 偽のスラッシュコマンドを作らない。`.agents/skills` のみ維持 |
| 定義の置き場 | リポジトリ直下 `commands/token-saver/*.md`（名前空間付き） |
| インストール単位 | `commands/token-saver/` を **1 パッケージ（ディレクトリ）** として設置 |
| 導入先パス | `$TARGET/.claude/commands/token-saver` → Claude Code 上は `/token-saver:report` など |
| 台帳キー | `commands` に `{name: "token-saver", src, mode}` を1件 |

Claude Code の慣習: `.claude/commands/<ns>/<cmd>.md` が `/<ns>:<cmd>` になる。

## 3. コマンド定義の薄さ

- 各ファイルは Claude Code が読む薄い Markdown（短い YAML frontmatter + 本文）
- 本文は「どの entrypoint/script を実行するか」だけを指示する
- 集計・閾値判定・設定更新のロジックをコマンド側へ複製しない
- `suggest-session-cut` は導入先 entrypoint が無いため、settings の Stop フックに登録された
  `suggest-session-cut.sh`、またはコマンド定義シンボリックリンクから辿れる
  `scripts/suggest-session-cut.sh` を実行する。stdin は Stop 相当の現セッション JSON
- 任意で `disable-model-invocation: true` を付与し、ユーザー明示呼び出し向けにする

## 4. 導入・台帳・取り外し

### 4.1 install.sh

- `commands/token-saver/` をディレクトリパッケージとして発見し、`.claude/commands/token-saver` へ設置
- `cts_place_skill` と同型の所有権判定をディレクトリ向けに置く（`cts_place_command`）
  - 既存の導入元リンク（クローン直下の `commands/token-saver` かつ親に `install.sh`）→ 触らない／差し替え可（legacy 許可時）
  - 既存ディレクトリで所有マーカー無し → 触らない
  - 既に同一ソースへのリンク → 成功扱い
  - コピー設置時の所有マーカーは `$dest/.claude-token-saver`（スキルと同じ）
- 台帳キー `commands` に `{name: "token-saver", src, mode}` を記録
- `.gitignore` の managed block へ実際に設置した `.claude/commands/token-saver` を追加
- Codex / `.agents` へはコマンドを置かない
- `cts_reject_managed_symlinks` に `.claude/commands`（必要ならその配下）を追加

### 4.2 lib/ledger.py

- `add-command` / `get-command` / `list-commands`
- `has-record` の `commands` 種別と `any` への包含

### 4.3 uninstall.sh

- 台帳の `commands` を正として所有物だけ外す（差し替え済みは残す）
- コピー時はディレクトリごと削除（所有マーカー付き）
- 空になった `.claude/commands` は片付ける
- 取り残しがある間は台帳と `.gitignore` を残す（スキルと同様）
- `--guess` は Claude の `.claude/commands` のみ。リンク先 basename=`token-saver`、親=`commands`、その親に `install.sh` があるときだけ外す

## 5. テスト・文書

- `test-install.sh` / `test-uninstall.sh` にコマンド設置・所有権・gitignore・Codex非設置・ledger `has-record commands`・往復を追加
- `test/expected-min-count` の総件数とファイル別件数を更新
- README にスラッシュコマンド節と install 手順の項目を追記
- Codex 側にコマンドを置かないことを明記

## 6. 非スコープ

- Claude Code plugin / marketplace 形式
- suggest-session-cut の導入先 entrypoint 新設
- スキルの廃止や途中の統合
- Codex へのスラッシュ直結の偽入口
