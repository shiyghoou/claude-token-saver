# 管理ディレクトリをルート直下へ移す 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** token-saver が管理する引き継ぎデータと台帳を `.claude/` 配下から導入先リポジトリのルート直下 `.token-saver/` へ移し、旧パスからの移行と検証を備える。

**Architecture:** パス文字列を `scripts/lib/paths.sh` の1箇所へ寄せ、`install.sh` / `uninstall.sh` / `scripts/lib/common.sh` がそこから組み立てる。`install.sh` は台帳を読む前に旧パスから新パスへデータを移す。`test/run.sh` に「実装コードにパスのリテラルが残っていたら打ち切る」静的ゲートを置き、直し忘れを緑のまま通さない。

**Tech Stack:** bash（3.2 互換必須）、python3（`lib/*.py`）、依存ゼロの自作テストランナー `test/run.sh`

設計書: `docs/specs/2026-07-31-token-saver-root-dir-design.md`

## Global Constraints

- **bash 3.2 で動くこと。** 連想配列（`declare -A`）、`mapfile`、`${var,,}`、`+=` での配列展開のガード無し参照を実装コード（`install.sh` / `uninstall.sh` / `scripts/**`）に持ち込まない。配列展開は必ず `${arr[@]+"${arr[@]}"}` の形でガードする。`test/run.sh` は開発環境の bash で走るため連想配列を使ってよい（既に使っている）。
- **フックは何が起きても終了コード 0 で抜ける。** `scripts/handoff-check.sh` の構造（サブシェル＋末尾 `exit 0`）を壊さない。
- **`set -uo pipefail` を各スクリプトの先頭で維持する。**
- **引き継ぎファイルは絶対に上書き・削除しない。** 移行で新側に同名がある場合は旧側に残して警告する。
- **新パス（リテラル）:** ルート直下 `.token-saver`、引き継ぎ `.token-saver/handoff`、その下に `pending` と `consumed`、台帳 `.token-saver/installed.json`。
- **旧パス（リテラル）:** 引き継ぎ `.claude/.handoff`、状態 `.claude/.token-saver`、台帳 `.claude/.token-saver/installed.json`。
- **動かさないもの:** `.claude/settings.local.json`（フック登録）、`.claude/skills/<name>`（スキル本体）。
- **`.gitignore` の claude-token-saver ブロックの本文:** 1行目 `.token-saver/`、続いて実際に設置したスキルごとに `.claude/skills/<name>`。
- **テストは各タスクの中で書き、緑にしてからコミットする。** テストを追加したら `test/expected-min-count` の該当ファイル行と総件数を実測値へ上げる（最終タスクでまとめて直すのではなく、そのタスクで直す）。
- **各タスクの最後にミューテーションでの実証を行う。** そのタスクで直した実装を1箇所壊し、そのタスクで書いたテストが赤になることを確認し、壊した箇所を元に戻す。赤にならなければテストが機能していない。

## File Structure

| ファイル | 役割 | 変更 |
|---|---|---|
| `scripts/lib/paths.sh` | パスの単一情報源。相対パスを返す関数だけを持つ | **新規** |
| `scripts/lib/common.sh` | フック共通処理。`cts_handoff_dir` / `cts_state_dir` を `paths.sh` から組み立てる | 変更（224-225 行付近） |
| `install.sh` | 導入。新パス作成、台帳パス、`.gitignore` ブロック、旧パスからの移行 | 変更 |
| `uninstall.sh` | 取り外し。新パスの後片付け、案内文、旧台帳フォールバック | 変更 |
| `test/run.sh` | 実装コードにパスのリテラルが残っていないかの静的ゲート | 変更（冒頭に追加） |
| `test/test-paths.sh` | `paths.sh` の契約テスト。リテラルを直書きする | **新規** |
| `test/test-install.sh` | 新パス・`.gitignore` 本文・移行のテスト | 変更 |
| `test/test-uninstall.sh` | 新パスの後片付け・案内文・旧台帳フォールバックのテスト | 変更 |
| `test/test-handoff-check.sh` | フックが新パスを読むことのテスト | 変更 |
| `test/test-handoff-consume.sh` | 同上 | 変更 |
| `test/test-runner-selftest.sh` | 静的ゲート自身のテスト | 変更 |
| `test/bash32-e2e.sh` | bash 3.2 実機確認を新パスで | 変更 |
| `test/expected-min-count` | 件数の下限 | 変更 |
| `README.md` | 配置・Codex の範囲・移行の説明 | 変更 |
| `skills/session-handoff/SKILL.md` | スキルが案内するパス | 変更 |
| `lib/ledger.py` | 台帳の位置に言及したコメント | 変更（コメントのみ） |
| `lib/settings-hooks.py` | 同上 | 変更（コメントのみ） |
| `docs/specs/2026-07-31-claude-token-saver-design.md` | §5.2 のレポート出力先を新パス基準に読み替え | 変更 |

---

### Task 1: パスの単一情報源 `scripts/lib/paths.sh`

**Files:**
- Create: `scripts/lib/paths.sh`
- Create: `test/test-paths.sh`
- Modify: `scripts/lib/common.sh:224-225`
- Modify: `test/expected-min-count`

**Interfaces:**
- Produces（後続タスクが依存する。名前と戻り値をこの通りにすること）:
  - `cts_base_rel()` → `.token-saver`
  - `cts_handoff_rel()` → `.token-saver/handoff`
  - `cts_ledger_rel()` → `.token-saver/installed.json`
  - `cts_legacy_handoff_rel()` → `.claude/.handoff`
  - `cts_legacy_state_rel()` → `.claude/.token-saver`
  - `cts_legacy_ledger_rel()` → `.claude/.token-saver/installed.json`
  - いずれも引数を取らず、末尾に改行を付けずに標準出力へ相対パスを書く。
- Consumes: なし

- [ ] **Step 1: 失敗するテストを書く**

`test/test-paths.sh` を新規作成する。**リテラルを直書きする**こと。`paths.sh` から
期待値を導出してはならない（実装とテストが同じ定義を見るだけになり、パスが
まるごと間違っていても緑になる）。

```bash
#!/usr/bin/env bash
# scripts/lib/paths.sh の契約テスト。
#
# ここだけはパスのリテラルを直書きする。paths.sh から期待値を導出すると
# 実装とテストが同じ定義を参照するだけになり、パスがまるごと間違っていても
# 両者が一致して緑になる。test/run.sh の静的ゲートも、この理由で test/ を
# 対象外にしている。

_load_paths() {
  # shellcheck disable=SC1090
  . "$REPO_ROOT/scripts/lib/paths.sh"
}

test_新パスの相対パスを返す() {
  _load_paths
  assert_eq ".token-saver" "$(cts_base_rel)" "cts_base_rel"
  assert_eq ".token-saver/handoff" "$(cts_handoff_rel)" "cts_handoff_rel"
  assert_eq ".token-saver/installed.json" "$(cts_ledger_rel)" "cts_ledger_rel"
}

test_旧パスの相対パスを返す() {
  _load_paths
  assert_eq ".claude/.handoff" "$(cts_legacy_handoff_rel)" "cts_legacy_handoff_rel"
  assert_eq ".claude/.token-saver" "$(cts_legacy_state_rel)" "cts_legacy_state_rel"
  assert_eq ".claude/.token-saver/installed.json" "$(cts_legacy_ledger_rel)" \
    "cts_legacy_ledger_rel"
}

test_新パスが_claude_配下を指さない() {
  _load_paths
  assert_not_contains "$(cts_base_rel)" ".claude" "cts_base_rel"
  assert_not_contains "$(cts_handoff_rel)" ".claude" "cts_handoff_rel"
  assert_not_contains "$(cts_ledger_rel)" ".claude" "cts_ledger_rel"
}

test_末尾に改行を付けない() {
  _load_paths
  local out
  out="$(printf '%sX' "$(cts_base_rel)")"
  assert_eq ".token-saverX" "$out" "改行が混ざっていない"
}

test_新パスは相対パスである() {
  _load_paths
  case "$(cts_base_rel)" in
    /*) _fail "cts_base_rel が絶対パスを返している: $(cts_base_rel)" ;;
  esac
  assert_ne "" "$(cts_base_rel)" "cts_base_rel が空でない"
}

test_フックの置き場所が新パスを組み立てる() {
  # common.sh は paths.sh を使って絶対パスを組み立てる。
  # cwd を渡さない場合は $PWD 基準になる。
  # shellcheck disable=SC1090
  . "$REPO_ROOT/scripts/lib/common.sh"
  assert_eq "$PWD/.token-saver/handoff" "$(cts_handoff_dir)" "cts_handoff_dir"
  assert_eq "$PWD/.token-saver" "$(cts_state_dir)" "cts_state_dir"
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
test/run.sh paths
```

期待: `test-paths.sh` が「FAIL (source 時にエラー出力)」または各テストが FAIL
（`scripts/lib/paths.sh` が存在しない）。`test-paths.sh` が台帳に無いため
件数の下限そのものは通ることに注意する。ここで緑になったら Step 1 が間違っている。

- [ ] **Step 3: `scripts/lib/paths.sh` を実装する**

```bash
#!/usr/bin/env bash
# token-saver が管理するパスの単一情報源。
#
# install.sh / uninstall.sh / scripts/lib/common.sh がこれを source する。
# パスを2箇所以上に書くと、片方だけ直したときに両方とも検証できなくなる
# （実測: 同じ検証を2層に書いた結果、どちらの層も改変を検出できなくなった）。
#
# ここで返すのは導入先リポジトリのルートからの相対パスだけである。絶対パスの
# 組み立ては呼び出し側が行う。install.sh は $TARGET を、フックは
# cts_project_dir を基準にするため、基準が1つに定まらない。
#
# 引き継ぎと台帳を .claude/ 配下ではなくルート直下へ置くのは、Claude Code 以外
# のエージェント（Codex CLI など）からも同じ場所を参照できるようにするためである。
# フック登録（.claude/settings.local.json）とスキル本体（.claude/skills/）は
# Claude Code がパスを決めるため動かせない。

cts_base_rel()           { printf '%s' '.token-saver'; }
cts_handoff_rel()        { printf '%s' '.token-saver/handoff'; }
cts_ledger_rel()         { printf '%s' '.token-saver/installed.json'; }

# 旧パス。install.sh の移行と uninstall.sh のフォールバックだけが使う。
cts_legacy_handoff_rel() { printf '%s' '.claude/.handoff'; }
cts_legacy_state_rel()   { printf '%s' '.claude/.token-saver'; }
cts_legacy_ledger_rel()  { printf '%s' '.claude/.token-saver/installed.json'; }
```

- [ ] **Step 4: `scripts/lib/common.sh` を新パスへ切り替える**

`scripts/lib/common.sh` の 224-225 行

```bash
cts_handoff_dir()  { printf '%s/.claude/.handoff' "$(cts_project_dir)"; }
cts_state_dir()    { printf '%s/.claude/.token-saver' "$(cts_project_dir)"; }
```

を次に置き換える。

```bash
cts_handoff_dir()  { printf '%s/%s' "$(cts_project_dir)" "$(cts_handoff_rel)"; }
cts_state_dir()    { printf '%s/%s' "$(cts_project_dir)" "$(cts_base_rel)"; }
```

併せて `scripts/lib/common.sh` の冒頭（`CTS_HOOK_PAYLOAD=""` の宣言より前、
ファイル先頭のコメントブロックの直後）に source を追加する。

```bash
# パスの単一情報源。common.sh 自身はフックから source されるため、
# 自分の位置を基準に隣を読む。
CTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=paths.sh
. "$CTS_LIB_DIR/paths.sh" || return 1
```

- [ ] **Step 5: `test/expected-min-count` を更新する**

`test-paths.sh 6` の行を（ファイル名のアルファベット順に合う位置へ）追加し、
総件数 `246` を `252` へ上げる。

```
252
test-handoff-check.sh 77
test-handoff-consume.sh 16
test-install.sh 56
test-paths.sh 6
test-runner-selftest.sh 44
test-uninstall.sh 53
```

- [ ] **Step 6: テストが通ることを確認する**

```bash
test/run.sh
```

期待: `成功 252 件 / 失敗 0 件`。`test-handoff-check.sh` と
`test-handoff-consume.sh` はまだ旧パスを前提にしているため落ちる可能性がある。
落ちたら Task 2 へ回さず**このタスクの中で**、テストが用意する引き継ぎ置き場を
新パスへ直す（`.claude/.handoff` → `.token-saver/handoff`）。フックの読み先が
変わったのだから、その期待値を直すのは同じ変更の一部である。

- [ ] **Step 7: ミューテーションで実証する**

1. `scripts/lib/paths.sh` の `cts_handoff_rel` の戻り値を `.token-saver/handoffs`
   （末尾に `s`）へ変える。
2. `test/run.sh paths` を実行し、`test_新パスの相対パスを返す` が **FAIL** に
   なることを確認する。
3. 戻り値を元に戻す。
4. `scripts/lib/common.sh` の `cts_handoff_dir` を `cts_base_rel` を使う形へ
   変える（`handoff` が抜けた状態）。
5. `test/run.sh paths` を実行し、`test_フックの置き場所が新パスを組み立てる` が
   **FAIL** になることを確認する。
6. 元に戻し、`test/run.sh` が全緑に戻ることを確認する。

- [ ] **Step 8: コミット**

```bash
git add scripts/lib/paths.sh scripts/lib/common.sh test/test-paths.sh \
        test/expected-min-count test/test-handoff-check.sh test/test-handoff-consume.sh
git commit -m "$(cat <<'EOF'
パスの単一情報源を作り、フックの読み先をルート直下へ移す

引き継ぎを Claude Code 以外のエージェントからも参照できる場所へ置くため、
読み先を .token-saver/handoff へ移した。パスを複数箇所に書くと片方だけ直した
ときに両方とも検証できなくなるため、定義は scripts/lib/paths.sh の1箇所に置く。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `install.sh` を新パスへ切り替える

**Files:**
- Modify: `install.sh:21-26`（`LEDGER`）, `install.sh:53-59`（ディレクトリ作成）, `install.sh:202-206`（`.gitignore` ブロック本文）
- Modify: `test/test-install.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: Task 1 の `cts_base_rel` / `cts_handoff_rel` / `cts_ledger_rel`
- Produces: `install.sh` は `$TARGET/.token-saver/handoff/{pending,consumed}` と
  `$TARGET/.token-saver` を作り、台帳を `$TARGET/.token-saver/installed.json` に
  置く。`.gitignore` ブロック本文の1行目は `.token-saver/`。

- [ ] **Step 1: 失敗するテストを書く**

`test/test-install.sh` に追加する。既存のテストが旧パスを期待している箇所は
このステップで新パスへ直す（追加と修正を分けない。同じ契約の変更である）。

既存テストのうち `.claude/.handoff` / `.claude/.token-saver` を期待値に
持つものを `grep -n '\.claude/\.handoff\|\.claude/\.token-saver' test/test-install.sh`
で洗い出し、すべて新パスへ直す。そのうえで次を追加する。

```bash
test_新パスに引き継ぎのディレクトリを作る() {
  _install
  assert_file_exists "$TARGET/.token-saver/handoff/pending" "pending"
  assert_file_exists "$TARGET/.token-saver/handoff/consumed" "consumed"
}

test_台帳を新パスに置く() {
  _install
  assert_file_exists "$TARGET/.token-saver/installed.json" "台帳"
}

test_claude_配下に引き継ぎのディレクトリを作らない() {
  _install
  assert_file_missing "$TARGET/.claude/.handoff" "旧の引き継ぎ置き場"
  assert_file_missing "$TARGET/.claude/.token-saver" "旧の状態置き場"
}

test_gitignore_はルート直下の1行で覆う() {
  _install
  local gi
  gi="$(cat "$TARGET/.gitignore")"
  assert_contains "$gi" ".token-saver/" ".gitignore"
  assert_not_contains "$gi" ".claude/.handoff/" ".gitignore"
  assert_not_contains "$gi" ".claude/.token-saver/" ".gitignore"
}

test_gitignore_はスキルの行を残す() {
  _install
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/session-handoff" \
    ".gitignore"
}
```

`_install` は `test/test-install.sh` の既存ヘルパーである。名前が違う場合は
ファイル冒頭のヘルパー定義を読んで合わせること。`assert_file_exists` は
ディレクトリにも使える（`test/lib/assert.sh` を確認して、ディレクトリ用の
アサーションが別にあるならそれを使う）。

- [ ] **Step 2: テストが失敗することを確認する**

```bash
test/run.sh install
```

期待: `test_新パスに引き継ぎのディレクトリを作る` ほかが FAIL。

- [ ] **Step 3: `install.sh` を実装する**

冒頭の `CTS_HOME` 解決の直後（`TARGET` の解決より後、`SETTINGS` の定義より前）に
source を追加する。

```bash
# パスの単一情報源。
# shellcheck source=scripts/lib/paths.sh
. "$CTS_HOME/scripts/lib/paths.sh" || {
  printf 'エラー: scripts/lib/paths.sh を読めない（クローンが不完全である）\n' >&2
  exit 1
}
```

`LEDGER` の定義（21-26 行付近）を次に変える。

```bash
LEDGER="$TARGET/$(cts_ledger_rel)"
```

ディレクトリ作成（53-59 行付近）を次に変える。

```bash
mkdir -p "$TARGET/$(cts_handoff_rel)/pending" \
         "$TARGET/$(cts_handoff_rel)/consumed" \
         "$TARGET/$(cts_base_rel)" ||
  die "ディレクトリを作成できない"
applied+=("$(cts_base_rel)/ のディレクトリを作成")
```

`.gitignore` ブロック本文（202-206 行付近）を次に変える。

```bash
{
  printf '%s/\n' "$(cts_base_rel)"
  for name in ${installed_skills[@]+"${installed_skills[@]}"}; do
    printf '.claude/skills/%s\n' "$name"
  done
} | python3 "$CTS_HOME/lib/gitignore-block.py" apply "$GITIGNORE"
```

`.claude/skills/%s` はここに直書きのまま残す。スキルの置き場所は Claude Code が
決める固定値であり、移動対象ではないためである。

- [ ] **Step 4: テストが通ることを確認する**

```bash
test/run.sh
```

期待: 全緑。`test/expected-min-count` の `test-install.sh` の件数と総件数を
実測値へ上げる（このタスクで 5 件増えるので `test-install.sh 61`、総件数 `257`）。
実際の件数は `test/run.sh install` の出力で数えて合わせること。

- [ ] **Step 5: ミューテーションで実証する**

1. `install.sh` の `.gitignore` ブロック本文の1行目を
   `printf '.claude/%s/\n' "$(cts_base_rel)"` へ変える。
2. `test/run.sh install` を実行し、`test_gitignore_はルート直下の1行で覆う` が
   **FAIL** になることを確認する。
3. 元に戻す。
4. `mkdir -p` の対象から `"$TARGET/$(cts_handoff_rel)/consumed"` を消す。
5. `test/run.sh install` を実行し、
   `test_新パスに引き継ぎのディレクトリを作る` が **FAIL** になることを確認する。
6. 元に戻し、全緑に戻ることを確認する。

- [ ] **Step 6: コミット**

```bash
git add install.sh test/test-install.sh test/expected-min-count
git commit -m "$(cat <<'EOF'
install.sh の設置先をルート直下へ移す

引き継ぎと台帳をエージェント中立な .token-saver/ 配下へ置く。.gitignore の
除外もルート直下の1行で覆えるようになった。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `install.sh` に旧パスからの移行を入れる

**Files:**
- Modify: `install.sh`（ディレクトリ作成の直後に移行ステップを挿入）
- Modify: `test/test-install.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: Task 1 の `cts_handoff_rel` / `cts_base_rel` / `cts_ledger_rel` /
  `cts_legacy_handoff_rel` / `cts_legacy_state_rel` / `cts_legacy_ledger_rel`、
  Task 2 の `install.sh` の `applied` / `warn` / `die`
- Produces: 旧パスの引き継ぎと台帳が新パスへ移る。移行は台帳を読む前に完了する。

- [ ] **Step 1: 失敗するテストを書く**

`test/test-install.sh` に追加する。

```bash
test_旧パスの引き継ぎを新パスへ移す() {
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.claude/.handoff/consumed"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf 'B\n' >"$TARGET/.claude/.handoff/consumed/b.md"
  _install
  assert_eq "A" "$(cat "$TARGET/.token-saver/handoff/pending/a.md")" "pending の中身"
  assert_eq "B" "$(cat "$TARGET/.token-saver/handoff/consumed/b.md")" "consumed の中身"
  assert_file_missing "$TARGET/.claude/.handoff/pending/a.md" "旧 pending"
  assert_file_missing "$TARGET/.claude/.handoff/consumed/b.md" "旧 consumed"
}

test_旧パスの台帳を新パスへ移す() {
  mkdir -p "$TARGET/.claude/.token-saver"
  printf '{"skills":{}}\n' >"$TARGET/.claude/.token-saver/installed.json"
  _install
  assert_file_exists "$TARGET/.token-saver/installed.json" "新台帳"
  assert_file_missing "$TARGET/.claude/.token-saver/installed.json" "旧台帳"
}

test_移行後は空になった旧ディレクトリを消す() {
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.claude/.token-saver"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  _install
  assert_file_missing "$TARGET/.claude/.handoff" "旧引き継ぎ置き場"
  assert_file_missing "$TARGET/.claude/.token-saver" "旧状態置き場"
}

test_新側に同名があれば上書きせず警告する() {
  mkdir -p "$TARGET/.claude/.handoff/pending" "$TARGET/.token-saver/handoff/pending"
  printf 'OLD\n' >"$TARGET/.claude/.handoff/pending/a.md"
  printf 'NEW\n' >"$TARGET/.token-saver/handoff/pending/a.md"
  local out
  out="$(_install 2>&1)"
  assert_eq "NEW" "$(cat "$TARGET/.token-saver/handoff/pending/a.md")" "新側は無傷"
  assert_eq "OLD" "$(cat "$TARGET/.claude/.handoff/pending/a.md")" "旧側は残る"
  assert_contains "$out" "警告" "衝突を警告する"
}

test_移行が起きたら適用一覧に載せる() {
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'A\n' >"$TARGET/.claude/.handoff/pending/a.md"
  local out
  out="$(_install 2>&1)"
  assert_contains "$out" "移行" "移行したことを伝える"
}

test_旧パスが無ければ移行を報告しない() {
  local out
  out="$(_install 2>&1)"
  assert_not_contains "$out" "移行" "新規導入では移行に触れない"
}

test_旧パスのシンボリックリンクはリンクごと移す() {
  mkdir -p "$TARGET/.claude/.handoff/pending"
  printf 'OUTSIDE\n' >"$TEST_TMP/outside.md"
  ln -s "$TEST_TMP/outside.md" "$TARGET/.claude/.handoff/pending/link.md"
  _install
  # リンクが実体化していないこと。実体化すると、リンク先の検証を
  # 読み取り時に行う設計（handoff-check.sh）が空回りする。
  if [ ! -L "$TARGET/.token-saver/handoff/pending/link.md" ]; then
    _fail "移行でシンボリックリンクが実体化した"
  fi
  assert_file_missing "$TARGET/.claude/.handoff/pending/link.md" "旧側のリンク"
}
```

`_install` が標準出力を返さないヘルパーの場合は、`out="$(_install 2>&1)"` が
使えるようにファイル冒頭のヘルパーを確認して合わせる。`assert_contains` の
呼び出しをコマンド置換の中に置いてはならない（`test/run.sh` の
「飲まれるアサーション」ゲートが赤にする）。

- [ ] **Step 2: テストが失敗することを確認する**

```bash
test/run.sh install
```

期待: 追加した 7 件が FAIL。

- [ ] **Step 3: 移行を実装する**

`install.sh` のディレクトリ作成（Task 2 で直した `mkdir -p` と `applied+=`）の
**直後**、`gitignore_existed` の判定より前に挿入する。

```bash
# --- 1b. 旧パスからの移行 ----------------------------------------------------
# 引き継ぎと台帳は以前 .claude/ 配下にあった。台帳を読む前に移す。台帳自身が
# 移動対象であり、先に読むと旧版の記録を見落として二重登録になる。
#
# 上書きは絶対にしない。引き継ぎは作業の記録であり、失うと事故の調査ができない。
# 衝突した1件は旧側に残し、利用者へ判断を渡す。
#
# mv で移すため、シンボリックリンクは追わずリンク自体が移る。リンク先の検証は
# 読み取り時（scripts/handoff-check.sh）が担う。ここで実体化させると、
# その検証が空回りする。
migrated=0
migrate_conflicts=0

cts_migrate_dir() {
  local from="$1" to="$2" entry base
  [ -d "$from" ] || return 0
  mkdir -p "$to" || die "移行先を作成できない: $to"
  for entry in "$from"/* "$from"/.*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    base="$(basename "$entry")"
    case "$base" in
      . | ..) continue ;;
    esac
    if [ -e "$to/$base" ] || [ -L "$to/$base" ]; then
      migrate_conflicts=$((migrate_conflicts + 1))
      warn "移行先に同名があるため移していない: $to/$base（旧側に残した）"
      continue
    fi
    mv "$entry" "$to/$base" || die "移行できない: $entry"
    migrated=$((migrated + 1))
  done
  return 0
}

cts_migrate_dir "$TARGET/$(cts_legacy_handoff_rel)/pending" \
                "$TARGET/$(cts_handoff_rel)/pending"
cts_migrate_dir "$TARGET/$(cts_legacy_handoff_rel)/consumed" \
                "$TARGET/$(cts_handoff_rel)/consumed"

# 台帳は1ファイルなので個別に扱う。
legacy_ledger="$TARGET/$(cts_legacy_ledger_rel)"
if [ -f "$legacy_ledger" ]; then
  if [ -e "$LEDGER" ]; then
    migrate_conflicts=$((migrate_conflicts + 1))
    warn "台帳が新旧の両方にあるため移していない: $legacy_ledger（旧側に残した）"
  else
    mkdir -p "$(dirname "$LEDGER")" || die "台帳の置き場所を作成できない"
    mv "$legacy_ledger" "$LEDGER" || die "台帳を移行できない"
    migrated=$((migrated + 1))
  fi
fi

# 空になった旧ディレクトリだけ片付ける。rmdir は空でなければ何もしないため、
# 衝突で残した実ファイルは従来どおり残る。
rmdir "$TARGET/$(cts_legacy_handoff_rel)/pending" \
      "$TARGET/$(cts_legacy_handoff_rel)/consumed" 2>/dev/null || true
rmdir "$TARGET/$(cts_legacy_handoff_rel)" \
      "$TARGET/$(cts_legacy_state_rel)" 2>/dev/null || true

if [ "$migrated" -gt 0 ]; then
  applied+=("旧パス（.claude 配下）から $migrated 件を移行")
fi
```

`for entry in "$from"/* "$from"/.*` は glob が一致しないときにパターン文字列
そのものを返すため、`[ -e "$entry" ] || [ -L "$entry" ] || continue` で弾く。
`.*` を含めるのは、引き継ぎファイルの名前がドットで始まる場合を落とさないため
である。`.` と `..` は `case` で除く。

`migrated` / `migrate_conflicts` は `set -u` の下で使うため、必ずここで
`0` に初期化してから参照する。

- [ ] **Step 4: テストが通ることを確認する**

```bash
test/run.sh
```

期待: 全緑。`test/expected-min-count` の `test-install.sh` を 7 件分、
総件数を 7 件分上げる（`test-install.sh 68`、総件数 `264`）。実測値で合わせること。

- [ ] **Step 5: ミューテーションで実証する**

1. 衝突判定 `if [ -e "$to/$base" ] || [ -L "$to/$base" ]; then` の分岐を消し、
   常に `mv` する（上書きする）ようにする。
2. `test/run.sh install` を実行し、`test_新側に同名があれば上書きせず警告する`
   が **FAIL** になることを確認する。
3. 元に戻す。
4. `mv` を `cp -rL` へ変える（リンクを実体化させる）。
5. `test_旧パスのシンボリックリンクはリンクごと移す` が **FAIL** になることを
   確認する。
6. 元に戻す。
7. 移行ブロック全体を台帳の読み込み（`settings-hooks.py install` の呼び出し）の
   **後ろ**へ移す。
8. `test_旧パスの台帳を新パスへ移す` が **FAIL** になることを確認する
   （新パスに台帳が作られた後に移行が走るため衝突警告になる）。
9. 元の位置に戻し、`test/run.sh` が全緑に戻ることを確認する。

- [ ] **Step 6: コミット**

```bash
git add install.sh test/test-install.sh test/expected-min-count
git commit -m "$(cat <<'EOF'
旧パスの引き継ぎと台帳を install.sh が移す

利用者に手動移行を求めないため。上書きは行わず、衝突した1件は旧側に残して
警告する。引き継ぎは作業の記録であり、失うと事故の調査ができないためである。
台帳自身が移動対象なので、移行は台帳を読む前に済ませる。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `uninstall.sh` を新パスへ切り替える

**Files:**
- Modify: `uninstall.sh:51-54`（`LEDGER`）, `uninstall.sh:229-243`（案内文）, `uninstall.sh:271-276`（`rmdir` の後片付け）
- Modify: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: Task 1 の `cts_base_rel` / `cts_handoff_rel` / `cts_ledger_rel` /
  `cts_legacy_handoff_rel` / `cts_legacy_state_rel`
- Produces: `uninstall.sh` は新パスの空ディレクトリを片付け、実ファイルがある
  引き継ぎは残す。

- [ ] **Step 1: 失敗するテストを書く**

`test/test-uninstall.sh` の既存テストのうち旧パスを期待値に持つものを
`grep -n '\.claude/\.handoff\|\.claude/\.token-saver' test/test-uninstall.sh`
で洗い出して新パスへ直し、そのうえで次を追加する。

```bash
test_新パスの空ディレクトリを片付ける() {
  _install
  _uninstall
  assert_file_missing "$TARGET/.token-saver/handoff/pending" "pending"
  assert_file_missing "$TARGET/.token-saver/handoff" "handoff"
  assert_file_missing "$TARGET/.token-saver" ".token-saver"
}

test_引き継ぎの実ファイルは残す() {
  _install
  printf 'A\n' >"$TARGET/.token-saver/handoff/consumed/a.md"
  _uninstall
  assert_file_exists "$TARGET/.token-saver/handoff/consumed/a.md" "引き継ぎ"
}

test_引き継ぎを残したことを新パスで案内する() {
  _install
  printf 'A\n' >"$TARGET/.token-saver/handoff/consumed/a.md"
  local out
  out="$(_uninstall 2>&1)"
  assert_contains "$out" ".token-saver/handoff" "案内文のパス"
  assert_not_contains "$out" ".claude/.handoff" "旧パスを案内しない"
}

test_新パスの台帳を消す() {
  _install
  _uninstall
  assert_file_missing "$TARGET/.token-saver/installed.json" "台帳"
}
```

- [ ] **Step 2: テストが失敗することを確認する**

```bash
test/run.sh uninstall
```

期待: 追加した 4 件が FAIL。

- [ ] **Step 3: `uninstall.sh` を実装する**

冒頭の `TARGET` 解決の直後、`SETTINGS` の定義より前に source を追加する。

```bash
# パスの単一情報源。
# shellcheck source=scripts/lib/paths.sh
. "$CTS_HOME/scripts/lib/paths.sh" || {
  printf 'エラー: scripts/lib/paths.sh を読めない（クローンが不完全である）\n' >&2
  exit 1
}
```

`LEDGER` を変える。

```bash
LEDGER="$TARGET/$(cts_ledger_rel)"
```

案内文（229-243 行付近）を変える。

```bash
if [ "${#warnings[@]}" -eq 0 ]; then
  rm -f "$LEDGER"
else
  info "  取り残しがあるため台帳を残した: $(cts_ledger_rel)"
fi

handoff_dir="$TARGET/$(cts_handoff_rel)"
if [ -d "$handoff_dir" ] && [ -n "$(find "$handoff_dir" -type f -print -quit 2>/dev/null)" ]; then
  info ""
  info "引き継ぎのファイルは残した: $(cts_handoff_rel)"
  info "  作業の記録であるため、アンインストールでは削除しない。不要なら手で削除せよ。"
  info "  .gitignore の除外は外れているので、版管理から外したいなら注意せよ。"
fi

state_dir="$TARGET/$(cts_base_rel)"
if [ -d "$state_dir" ] && [ -n "$(find "$state_dir" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]; then
  info "状態ファイルは残した: $(cts_base_rel)"
fi
```

`state_dir` の `find` に `-maxdepth 1` を足すのは、`.token-saver/` が
`handoff/` を内包するようになったためである。付けないと、引き継ぎが残って
いるだけで「状態ファイルは残した」と二重に案内する。

後片付けの `rmdir`（271-276 行付近）を変える。

```bash
  # install.sh が作った空の器を残さない。rmdir は空でなければ何もしないので、
  # 実ファイルのある引き継ぎは従来どおり残る。深い側から順に消す。
  rmdir "$handoff_dir/pending" "$handoff_dir/consumed" 2>/dev/null || true
  rmdir "$handoff_dir" 2>/dev/null || true
  rmdir "$state_dir" 2>/dev/null || true
```

`$state_dir` は `$handoff_dir` の親であるため、`handoff` を消した**後**に
消す必要がある。1つの `rmdir` 呼び出しに並べると引数の順に処理されるとはいえ、
意図を読み違えやすいので行を分ける。

`rmdir "$TARGET/.claude"` の行はそのまま残す（スキルを外して空になれば消える）。

- [ ] **Step 4: テストが通ることを確認する**

```bash
test/run.sh
```

期待: 全緑。`test/expected-min-count` の `test-uninstall.sh` を 4 件分、
総件数を 4 件分上げる（`test-uninstall.sh 57`、総件数 `268`）。実測値で合わせること。

- [ ] **Step 5: ミューテーションで実証する**

1. `rmdir "$state_dir"` の行を消す。
2. `test/run.sh uninstall` を実行し、`test_新パスの空ディレクトリを片付ける` が
   **FAIL** になることを確認する。
3. 元に戻す。
4. `rmdir "$handoff_dir/pending" ...` を `rm -rf "$handoff_dir"` へ変える。
5. `test_引き継ぎの実ファイルは残す` が **FAIL** になることを確認する。
6. 元に戻し、全緑に戻ることを確認する。

- [ ] **Step 6: コミット**

```bash
git add uninstall.sh test/test-uninstall.sh test/expected-min-count
git commit -m "$(cat <<'EOF'
uninstall.sh の後片付けと案内をルート直下のパスへ合わせる

引き継ぎの実ファイルは従来どおり残す。.token-saver/ が handoff/ を内包する
ようになったため、状態ファイルの案内は深さ1に限って判定する。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `uninstall.sh` に旧台帳のフォールバックを入れる

**Files:**
- Modify: `uninstall.sh:74-77`（台帳の有無の判定）
- Modify: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: Task 1 の `cts_legacy_ledger_rel`、Task 4 の `uninstall.sh` の `LEDGER`
- Produces: 新パスに台帳が無く旧パスにある場合、`uninstall.sh` は旧台帳を
  読んで取り外す。旧台帳へ書き込みはしない。

これが無いと「旧版で install → 新版で uninstall」で台帳が見つからず、
fail-closed により利用者のフックを残したまま終わる。事故ではないが外せなくなる。

- [ ] **Step 1: 失敗するテストを書く**

`test/test-uninstall.sh` に追加する。

```bash
test_旧パスの台帳を読んで外す() {
  _install
  # 旧版の状態を作る: 台帳を旧パスへ戻す。
  mkdir -p "$TARGET/.claude/.token-saver"
  mv "$TARGET/.token-saver/installed.json" \
     "$TARGET/.claude/.token-saver/installed.json"
  _uninstall
  # フックが外れていること。推測に落ちていないこと。
  assert_not_contains "$(cat "$TARGET/.claude/settings.local.json")" \
    "handoff-check.sh" "フックが外れている"
  assert_file_missing "$TARGET/.claude/skills/session-handoff" "スキルのリンク"
}

test_旧台帳を読んでも旧台帳へ書き込まない() {
  _install
  mkdir -p "$TARGET/.claude/.token-saver"
  mv "$TARGET/.token-saver/installed.json" \
     "$TARGET/.claude/.token-saver/installed.json"
  local before after
  before="$(cat "$TARGET/.claude/.token-saver/installed.json")"
  _uninstall
  if [ -f "$TARGET/.claude/.token-saver/installed.json" ]; then
    after="$(cat "$TARGET/.claude/.token-saver/installed.json")"
    assert_eq "$before" "$after" "旧台帳の内容"
  else
    assert_file_missing "$TARGET/.claude/.token-saver/installed.json" "旧台帳は消えてよい"
  fi
}

test_新旧どちらにも台帳が無ければ推測に落ちない() {
  _install
  rm -f "$TARGET/.token-saver/installed.json"
  _uninstall
  # fail-closed。利用者のフックを勝手に消さない。
  assert_contains "$(cat "$TARGET/.claude/settings.local.json")" \
    "handoff-check.sh" "台帳が無ければフックを残す"
}
```

3件目は既存テストと重複する可能性がある。`grep -n '記録の無い台帳' test/test-uninstall.sh`
で確認し、同じ検証が既にあるなら3件目は追加しない（件数を稼ぐための重複を
入れない。`test/run.sh` の重複検出は同名関数だけを見るため、内容の重複は
検出されない）。

- [ ] **Step 2: テストが失敗することを確認する**

```bash
test/run.sh uninstall
```

期待: `test_旧パスの台帳を読んで外す` が FAIL。

- [ ] **Step 3: フォールバックを実装する**

`uninstall.sh` の台帳判定（74-77 行付近）を次に変える。

```bash
# 新パスに台帳が無く、旧パス（.claude 配下）にあるなら、そちらを読む。
# 旧版で導入したあと新版で取り外す経路である。フォールバックが無いと台帳を
# 見つけられず、fail-closed で利用者のフックを残したまま終わる。
# 読むだけで、旧台帳へは書き込まない。旧パスは移行元であり、書き戻すと
# install.sh の移行が次回また同じものを拾う。
LEGACY_LEDGER="$TARGET/$(cts_legacy_ledger_rel)"
if ! python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" any &&
   python3 "$CTS_HOME/lib/ledger.py" has-record "$LEGACY_LEDGER" any; then
  info "  旧パスの台帳を使う: $(cts_legacy_ledger_rel)"
  LEDGER="$LEGACY_LEDGER"
fi

have_ledger=0
have_skill_record=0
python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" any && have_ledger=1
python3 "$CTS_HOME/lib/ledger.py" has-record "$LEDGER" skills && have_skill_record=1
```

`ledger.py has-record` は存在しないパスに対しても終了コードで答える（`lib/ledger.py`
の実装を読んで確認すること。例外で落ちるなら `2>/dev/null` を足す）。

`LEDGER` を差し替えた場合、Task 4 の「取り残しがあるため台帳を残した」の
案内文は旧パスを指さなければならない。差し替えたかどうかを変数で持ち、
案内文でそれを使う。

Task 4 で書いた案内文を次に直す。

```bash
# 案内するパスは、実際に読んだ台帳のものでなければならない。旧パスへ
# フォールバックしたときに新パスを案内すると、利用者が消す先を間違える。
LEDGER_REL="$(cts_ledger_rel)"
```

を `LEDGER` の定義の直後に置き、フォールバックの中で
`LEDGER_REL="$(cts_legacy_ledger_rel)"` へ差し替える。案内文は
`info "  取り残しがあるため台帳を残した: $LEDGER_REL"` とする。

パスを2つ持つのではなく、絶対パスの `LEDGER` と表示用の相対パス `LEDGER_REL`
を対で差し替える。`$LEDGER` から `$TARGET/` を文字列操作で削って表示に使う
手も動くが、`$TARGET` に記号が入ったときの挙動を考えなければならなくなる。

- [ ] **Step 4: テストが通ることを確認する**

```bash
test/run.sh
```

期待: 全緑。`test/expected-min-count` を実測値へ上げる。

- [ ] **Step 5: ミューテーションで実証する**

1. フォールバックの `if` 条件を `if false; then` へ変える。
2. `test/run.sh uninstall` を実行し、`test_旧パスの台帳を読んで外す` が
   **FAIL** になることを確認する。
3. 元に戻す。
4. `LEDGER="$LEGACY_LEDGER"` の行を消す（案内だけ出して差し替えない）。
5. 同じテストが **FAIL** になることを確認する。
6. 元に戻し、全緑に戻ることを確認する。

- [ ] **Step 6: コミット**

```bash
git add uninstall.sh test/test-uninstall.sh test/expected-min-count
git commit -m "$(cat <<'EOF'
旧パスの台帳を uninstall.sh が読めるようにする

旧版で導入したあと新版で取り外すと台帳が見つからず、fail-closed で利用者の
フックが残ったまま外せなくなる。読むだけで旧台帳へは書き込まない。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: bash 3.2 の実機確認を新パスへ

**Files:**
- Modify: `test/bash32-e2e.sh:37-53`

**Interfaces:**
- Consumes: Task 1〜5 の実装
- Produces: なし（CI の `bash32` ジョブが新パスで通る）

- [ ] **Step 1: 現状を確認する**

```bash
grep -n '\.claude/\.handoff' test/bash32-e2e.sh
```

期待: 37, 39, 47, 48, 52, 53 行あたりが一致する。

- [ ] **Step 2: 新パスへ直す**

`test/bash32-e2e.sh` の `.claude/.handoff` を `.token-saver/handoff` へ置き換える。
**このファイルはリテラルを直書きしたままにする**（docker の中で `paths.sh` を
source すると、実装と同じ定義を見るだけになり実機確認の値打ちが落ちる）。

置換対象:

```
mkdir -p "$proj/.claude/.handoff/pending"      -> "$proj/.token-saver/handoff/pending"
  >"$proj/.claude/.handoff/pending/2026-...md" -> "$proj/.token-saver/handoff/pending/..."
ls -A "$proj/.claude/.handoff/pending"         -> "$proj/.token-saver/handoff/pending"
ls -A "$proj/.claude/.handoff/consumed"        -> "$proj/.token-saver/handoff/consumed"
rm -rf "$proj/.claude/.handoff/pending"        -> "$proj/.token-saver/handoff/pending"
mkdir -p "$proj/.claude/.handoff/pending"      -> "$proj/.token-saver/handoff/pending"
```

`consumed` ディレクトリを作る行が無い場合は、`pending` と並べて
`mkdir -p "$proj/.token-saver/handoff/consumed"` を足す（フックは
`consumed` が無いと移せない）。ファイル全体を読んで、既存の作り方に合わせること。

- [ ] **Step 3: docker で実機確認する**

```bash
test/bash32-e2e.sh
```

期待: `PENDING=0` / `CONSUMED=1` と出て終了コード 0。docker が使えない環境では
このステップを飛ばさず、ユーザーへ「docker が無いため bash 3.2 の実機確認が
できない」と報告すること（黙って飛ばしてはならない）。

- [ ] **Step 4: ミューテーションで実証する**

1. `test/bash32-e2e.sh` の `mkdir -p "$proj/.token-saver/handoff/consumed"` を消す。
2. `test/bash32-e2e.sh` を実行し、**失敗する**ことを確認する（consumed が無いと
   フックが引き継ぎを移せない）。
3. 元に戻し、通ることを確認する。

- [ ] **Step 5: コミット**

```bash
git add test/bash32-e2e.sh
git commit -m "$(cat <<'EOF'
bash 3.2 の実機確認を新パスで行う

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: パスの単一情報源を守る静的ゲート

**Files:**
- Modify: `test/run.sh`（`_check_assert_layer` 呼び出しの直後）
- Modify: `test/test-runner-selftest.sh`
- Modify: `test/expected-min-count`
- Modify: `lib/ledger.py`（コメント）, `lib/settings-hooks.py`（コメント）, `test/lib/assert.sh`（コメント）

**Interfaces:**
- Consumes: Task 1〜6 の実装（リテラルが `paths.sh` へ寄っている状態）
- Produces: `test/run.sh` は実装コードにパスのリテラルが残っていればテストを
  1本も走らせずに終了コード 1 で打ち切る。

このタスクは Task 1〜6 の**後**に置く。先に入れると、まだ移していない
リテラルで打ち切られて他のタスクが進まない。

- [ ] **Step 1: 現状の違反を洗い出す**

```bash
grep -rn '\.token-saver\|\.claude/\.handoff' \
  install.sh uninstall.sh scripts lib \
  | grep -v '^scripts/lib/paths\.sh:'
```

期待: 何も出ない。出たら、それが直し忘れである。`lib/ledger.py` と
`lib/settings-hooks.py` のコメントは一致するので、コメント文からパスを
落とすか新パスへ直す。**コメントも対象に含めるのは意図である**（古いパスを
語るコメントは、次に読む人を旧パスへ誘導する）。

`lib/ledger.py:25` のコメント

```python
# 台帳自身は .claude/.token-saver/ に置く。既に .gitignore の対象である。
```

を次に直す。

```python
# 台帳自身の置き場所は install.sh が決める（scripts/lib/paths.sh を正とする）。
# .gitignore の対象であり、版管理へは入らない。
```

`lib/settings-hooks.py:15` と `lib/ledger.py:138` のコメントも同様に、
具体パスを書かず「台帳」「スキルの置き場所」と述べる形へ直す。

`test/lib/assert.sh:60` のコメントは `test/` 配下なのでゲートの対象外だが、
旧パスを例に挙げているので新パスへ直す。

- [ ] **Step 2: ゲート自身のテストを書く**

`test/test-runner-selftest.sh` に追加する。このファイルは `test/run.sh` を
別プロセスで実行して挙動を検べる既存のセルフテストである。ファイル冒頭の
ヘルパー（テスト用の偽リポジトリを組む関数）を読んで、その作法に合わせること。

```bash
test_実装コードに新パスのリテラルがあれば打ち切る() {
  local fake
  fake="$(_fake_repo)"
  printf 'echo ".token-saver/handoff"\n' >>"$fake/scripts/handoff-check.sh"
  local out st=0
  out="$("$fake/test/run.sh" 2>&1)" || st=$?
  assert_ne "0" "$st" "終了コード"
  assert_contains "$out" "scripts/handoff-check.sh" "違反したファイル名"
}

test_実装コードに旧パスのリテラルがあれば打ち切る() {
  local fake
  fake="$(_fake_repo)"
  printf 'echo ".claude/.handoff"\n' >>"$fake/install.sh"
  local out st=0
  out="$("$fake/test/run.sh" 2>&1)" || st=$?
  assert_ne "0" "$st" "終了コード"
  assert_contains "$out" "install.sh" "違反したファイル名"
}

test_paths_sh_自身のリテラルは許す() {
  local fake
  fake="$(_fake_repo)"
  local out st=0
  out="$("$fake/test/run.sh" paths 2>&1)" || st=$?
  assert_eq "0" "$st" "終了コード"
  assert_not_contains "$out" "パスのリテラル" "ゲートに掛からない"
}

test_テスト側のリテラルは許す() {
  local fake
  fake="$(_fake_repo)"
  printf 'echo ".token-saver"\n' >>"$fake/test/test-paths.sh"
  local out st=0
  out="$("$fake/test/run.sh" paths 2>&1)" || st=$?
  # 構文としては通る行なので、ゲートで打ち切られないことだけを見る。
  assert_not_contains "$out" "パスのリテラル" "test/ は対象外"
}

test_ゲートはテストより前に走る() {
  local fake
  fake="$(_fake_repo)"
  printf 'echo ".token-saver"\n' >>"$fake/install.sh"
  local out st=0
  out="$("$fake/test/run.sh" 2>&1)" || st=$?
  assert_ne "0" "$st" "終了コード"
  # 1本も実行されていないこと。「他は緑だから大丈夫」と読まれる余地を残さない。
  assert_not_contains "$out" "  ok   " "テストが走っていない"
}
```

`_fake_repo` は既存のヘルパー名に合わせること。既存のセルフテストが
`$REPO_ROOT` をそのまま使って `test/run.sh` を叩く作りなら、リポジトリ本体を
汚さないよう `cp -R` で `$TEST_TMP` へ複製するヘルパーを新規に作る
（`.git` は除く）。複製する対象は `test/`、`scripts/`、`lib/`、`install.sh`、
`uninstall.sh` である。

- [ ] **Step 3: テストが失敗することを確認する**

```bash
test/run.sh runner-selftest
```

期待: 追加した 5 件のうち、打ち切りを期待する 3 件が FAIL（ゲートが無いため
終了コードが 0 になる）。

- [ ] **Step 4: ゲートを実装する**

`test/run.sh` の `_check_assert_layer` 呼び出し（117 行）の直後に挿入する。

```bash
# ---- パスの単一情報源の検査 ----------------------------------------------
# token-saver が管理するパスの定義は scripts/lib/paths.sh の1箇所だけに置く。
# 実装コードに直書きが残ると、片方だけ直したときにテストが緑のまま通る
# （実測: 同じ定義を2層に書いた結果、どちらの層も改変を検出できなくなった）。
#
# 対象は実装コードだけである。test/ を対象外にするのは意図である。テスト側も
# paths.sh から導出させると、実装とテストが同じ定義を見るだけになり、パスが
# まるごと間違っていても両者が一致して緑になる。契約テストはリテラルを直書きする。
#
# 違反があればテストを1本も走らせずに打ち切る。1箇所の直し忘れを
# 「他は緑だから大丈夫」と読ませないためである。
_check_path_literals() {
  local targets=() hits
  [ -f "$REPO_ROOT/install.sh" ] && targets+=("$REPO_ROOT/install.sh")
  [ -f "$REPO_ROOT/uninstall.sh" ] && targets+=("$REPO_ROOT/uninstall.sh")
  [ -d "$REPO_ROOT/scripts" ] && targets+=("$REPO_ROOT/scripts")
  [ -d "$REPO_ROOT/lib" ] && targets+=("$REPO_ROOT/lib")

  if [ "${#targets[@]}" -eq 0 ]; then
    printf 'エラー: パス検査の対象が1つも無い: %s\n' "$REPO_ROOT" >&2
    printf '       実装コードが消えているか REPO_ROOT が誤っている。\n' >&2
    exit 1
  fi

  # -F は使えない（複数パターンを別々に扱いたい）。固定文字列として扱うため
  # メタ文字はエスケープ済みのパターンを書く。
  hits="$(grep -rnE '\.token-saver|\.claude/\.handoff' "${targets[@]}" 2>/dev/null \
    | grep -v '/scripts/lib/paths\.sh:' || true)"

  if [ -n "$hits" ]; then
    printf 'エラー: 実装コードにパスのリテラルが残っている\n' >&2
    printf '       定義は scripts/lib/paths.sh の1箇所だけに置くこと。\n' >&2
    printf '%s\n' "$hits" >&2
    exit 1
  fi
}

_check_path_literals
```

`REPO_ROOT` は 18 行で既に定義されている。`targets` の配列展開はガード不要
（直前に空判定している）が、`test/run.sh` は開発環境の bash で動くため
bash 3.2 の制約は掛からない。

- [ ] **Step 5: テストが通ることを確認する**

```bash
test/run.sh
```

期待: 全緑。`test/expected-min-count` の `test-runner-selftest.sh` と総件数を
実測値へ上げる。

- [ ] **Step 6: ミューテーションで実証する**

1. `_check_path_literals` の `exit 1` を `return 0` へ変える。
2. `test/run.sh runner-selftest` を実行し、打ち切りを期待する 3 件が **FAIL**
   になることを確認する。
3. 元に戻す。
4. `grep -v '/scripts/lib/paths\.sh:'` の除外を消す。
5. `test/run.sh` を実行し、`paths.sh` 自身で打ち切られることを確認する
   （＝除外が効いていることの裏返し）。
6. 元に戻す。
7. `_check_path_literals` の呼び出しを `test/run.sh` の**末尾**（`exit 0` の
   直前）へ移す。
8. `test_ゲートはテストより前に走る` が **FAIL** になることを確認する。
9. 元の位置に戻し、全緑に戻ることを確認する。

- [ ] **Step 7: コミット**

```bash
git add test/run.sh test/test-runner-selftest.sh test/expected-min-count \
        lib/ledger.py lib/settings-hooks.py test/lib/assert.sh
git commit -m "$(cat <<'EOF'
実装コードへのパス直書きをテストランナーで塞ぐ

パスの定義が2箇所に分かれると、片方だけ直したときにどちらの層も改変を
検出できなくなる。違反があればテストを1本も走らせずに打ち切る。テストは
対象外にする。テストも同じ定義を見ると、パスがまるごと間違っていても
両者が一致して緑になるためである。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: ドキュメントを実装へ追随させる

**Files:**
- Modify: `README.md`
- Modify: `skills/session-handoff/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`

**Interfaces:**
- Consumes: Task 1〜7 の実装
- Produces: なし

- [ ] **Step 1: 現状の記述を洗い出す**

```bash
grep -rn '\.claude/\.handoff\|\.claude/\.token-saver' README.md skills docs
```

一致した箇所すべてを新パスへ直す。

- [ ] **Step 2: `README.md` に配置の節を書く**

配置を説明する既存の節（`grep -n '配置\|ディレクトリ' README.md` で探す）へ、
次の3点を書く。文体は README の既存の記述に合わせること（断定形、日本語）。

1. **配置**

```
<導入先>/
  .token-saver/          ← token-saver が管理する。.gitignore で除外される
    handoff/
      pending/           ← 未消費の引き継ぎ
      consumed/          ← 消費済みの引き継ぎ（記録として残る）
    installed.json       ← 何を設置したかの台帳
  .claude/
    settings.local.json  ← フックの登録先。Claude Code がパスを決めるため動かせない
    skills/session-handoff
```

2. **Codex との関係**（範囲を誤解させないこと）

> `.token-saver/` をルート直下に置くのは、Claude Code 以外のエージェント
> （Codex CLI など）からも同じ引き継ぎを参照できるようにするためである。
> ただし**現時点で Codex 側から自動で読み込む仕掛けは無い**。フックの登録先と
> スキル本体は Claude Code がパスを決めるため `.claude/` に残る。Codex から
> 読ませるには Codex 側のアダプタが別途必要であり、それは今後の段階で扱う。
>
> リポジトリ名が `claude-token-saver` でディレクトリ名が `.token-saver` である
> のは意図的で、管理するデータをツール中立にする一歩である。

3. **移行**

> 以前の版は引き継ぎを `.claude/.handoff/`、台帳を `.claude/.token-saver/` に
> 置いていた。`install.sh` が新パスへ移すため、手動での移行は要らない。移行先に
> 同名のファイルがある場合は上書きせず旧側に残し、警告する。

- [ ] **Step 3: `skills/session-handoff/SKILL.md` を直す**

引き継ぎの置き場所を案内している箇所を新パスへ直す。**スキルの本文は
セッション開始時にコンテキストへ入るため、行数を増やさない。**
パスの文字列を差し替えるだけにとどめ、Codex に関する説明は README 側に置く。

- [ ] **Step 4: 既存設計書を直す**

`docs/specs/2026-07-31-claude-token-saver-design.md` の該当箇所（§5.2 と
実装フェーズの表の周辺、`docs/specs/...:288` 付近）で、パスに言及している
記述を新パスへ直す。併せて冒頭かレポート出力先の節に1行足す。

> 引き継ぎと台帳の置き場所は `docs/specs/2026-07-31-token-saver-root-dir-design.md`
> で `.token-saver/` 配下へ改訂した。段階2のレポート出力先もその配下へ置く。

- [ ] **Step 5: 全体を通して確認する**

```bash
test/run.sh
grep -rn '\.claude/\.handoff\|\.claude/\.token-saver' README.md skills docs install.sh uninstall.sh scripts lib
```

期待: テストは全緑。`grep` の一致は、移行と旧版について**意図して**述べている
箇所（README の移行の節、`scripts/lib/paths.sh` の旧パス定義、新旧を語る設計書）
だけであること。それ以外が残っていたら直す。

- [ ] **Step 6: コミット**

```bash
git add README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md
git commit -m "$(cat <<'EOF'
配置の変更と Codex 対応の範囲を文書へ反映する

置き場所を共有可能にしたところまでが今回の範囲であり、Codex 側から自動で
読み込む仕掛けは無いことを明記する。範囲を書かないと、動かないものが
動くと読まれる。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: 通しの検証と PR の更新

**Files:**
- Modify: なし（検証と報告のみ）

**Interfaces:**
- Consumes: Task 1〜8
- Produces: なし

- [ ] **Step 1: テストを全件走らせる**

```bash
test/run.sh
```

期待: 全緑。`実行件数の下限: 総 N 件 / ファイル別 6 件分` の N が
`test/expected-min-count` と一致すること。

- [ ] **Step 2: bash 3.2 の実機確認**

```bash
test/bash32-e2e.sh
```

期待: 終了コード 0。docker が無い環境なら、飛ばしたことをユーザーへ報告する。

- [ ] **Step 3: 実際に導入と取り外しを一往復する**

`$TMPDIR` に空の git リポジトリを作り、`install.sh` → `uninstall.sh` を通す。

```bash
tmp="$(mktemp -d)"
git -C "$tmp" init -q
./install.sh "$tmp"
find "$tmp" -name '.git' -prune -o -print | LC_ALL=C sort
./uninstall.sh "$tmp"
find "$tmp" -name '.git' -prune -o -print | LC_ALL=C sort
rm -rf "$tmp"
```

期待: install 後に `.token-saver/handoff/{pending,consumed}` と
`.token-saver/installed.json` があり、`.claude/.handoff` が無い。
uninstall 後に `.token-saver` が消え、`.gitignore` からブロックが消えている。

- [ ] **Step 4: 旧パスからの移行を実地で確かめる**

```bash
tmp="$(mktemp -d)"
git -C "$tmp" init -q
mkdir -p "$tmp/.claude/.handoff/pending" "$tmp/.claude/.token-saver"
printf 'OLD HANDOFF\n' >"$tmp/.claude/.handoff/pending/old.md"
./install.sh "$tmp"
cat "$tmp/.token-saver/handoff/pending/old.md"
ls -a "$tmp/.claude"
rm -rf "$tmp"
```

期待: `OLD HANDOFF` が出て、`.claude` に `.handoff` と `.token-saver` が無い。

- [ ] **Step 5: CI を確認する**

```bash
git push
gh pr checks 1
```

期待: `test` と `bash32` が SUCCESS。

- [ ] **Step 6: ユーザーへ報告する**

次を報告する。

- テスト件数（変更前 246 件 → 変更後の実測値）
- Step 3・Step 4 の実地確認の結果
- CI の結果
- 4巡目の敵対的レビューを実施するか判断を仰ぐ（この変更は `install.sh` /
  `uninstall.sh` / `test/run.sh` の中核に触るため、レビューの対象になる）

**このタスクでコミットや push を勝手に済ませてはならない。** push は Step 5 で
行うが、`squash merge` はユーザーの指示を待つ。
