# 段階5: 委譲判断ガイドと移植元の切り替え Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 必要時だけ読み込む委譲判断スキルを追加し、既存installerの安全契約で配布・取り外しできるようにして、本リポジトリを委譲方針の正へ切り替える手順を完成させる。

**Architecture:** 判断ロジックは実行コードや常駐指示へ入れず、単独の `SKILL.md` に閉じ込める。配布は既存の `skills/*/` 自動発見を再利用し、専用のinstaller分岐を追加しない。段階4とは診断を人が参考にする疎結合だけを持ち、snapshot schemaや設定更新へ依存しない。

**Tech Stack:** Markdown skill、Bash 3.2互換の既存installer/uninstaller、依存ゼロのBashテストランナー、Python 3.6互換の既存台帳処理。

## Global Constraints

- Issue #25の番号付きブランチで作業し、`main`へ直接編集しない。
- Luna Maxを唯一の実装エージェントとして使用し、controllerは設計、diff確認、テスト、最終reviewを所有する。
- 既存の公開CLI、環境変数、設定JSON、台帳schema、フック出力、既存スキルを変更しない。
- 委譲を自動発火せず、`delegation-policy`は必要時だけ明示的に読み込む。
- 段階4のsnapshot schemaを解析せず、計測値だけで設定や委譲先を自動変更しない。
- 特定モデル名、価格、固定トークン数を普遍的な規則として記述しない。
- 非公開の移植元リポジトリと実測レポートを変更・複製しない。
- 起動したサブエージェントの結果は必ず回収する方針をスキル契約に含める。
- 実装後は実diff、全テスト、Python互換性、Bash 3.2 E2E、diff checkをcontrollerが確認する。
- PR作成後はユーザーへマージを依頼し、エージェントはマージしない。

---

## ファイル構成と責務

- Create: `skills/delegation-policy/SKILL.md`
  - 読み込み条件、判断順序、委譲しない条件、能力帯、結果回収、数値の限界を定義する。
- Create: `test/test-delegation-policy.sh`
  - skillと文書の契約を文字列・構造で検証する。
- Modify: `test/test-install.sh`
  - `delegation-policy`のリンク、コピー、台帳、`.gitignore`、同名保護を実名で検証する。
- Modify: `test/test-uninstall.sh`
  - `delegation-policy`の所有物だけの削除、同名保護、往復を実名で検証する。
- Modify: `test/expected-min-count`
  - 追加したテスト関数の実測件数を下限へ反映する。
- Modify: `README.md`
  - 状態表、利用方法、判断要約、移植元の安全な切り替え手順を追加する。
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
  - §5.4と段階表を実装内容へ合わせ、段階1〜5完了を記録する。

`install.sh`、`uninstall.sh`、`lib/ledger.py`は変更しない。新スキルが既存の一般化された発見・所有権契約で動かない場合だけ、controllerへ停止報告して設計変更を求める。

---

### Task 1: 委譲判断スキルを契約テストから実装する

**Files:**
- Create: `test/test-delegation-policy.sh`
- Create: `skills/delegation-policy/SKILL.md`
- Modify: `test/expected-min-count`

**Interfaces:**
- skill frontmatterの`name`は`delegation-policy`とする。
- frontmatterの`description`は、重い作業の委譲判断・並列化・能力帯選択が必要な場面を読み込み条件として表す。
- 本文の判断順序は「非コスト理由 → 作業の重さと会話期間 → 起動/統合費 → 能力帯と境界 → 結果回収」とする。
- 段階4は参考情報に限定し、snapshot JSONや設定更新へ接続しない。

- [ ] **Step 1: skill契約の失敗テストを8件書く**

`test/test-delegation-policy.sh`に既存の`test/lib/assert.sh`を使い、次の関数を作る。

```bash
SKILL="$REPO_ROOT/skills/delegation-policy/SKILL.md"

_skill_text() {
  assert_file_exists "$SKILL" "delegation-policy skill"
  cat "$SKILL"
}

test_frontmatter名と必要時の読み込み条件を持つ() {
  body="$(_skill_text)"
  assert_contains "$body" "name: delegation-policy" "frontmatter name"
  assert_contains "$body" "重い" "on-demand description"
}

test_非コスト理由を先に判断する() {
  body="$(_skill_text)"
  assert_contains "$body" "並列化" "並列化"
  assert_contains "$body" "ツール制限" "ツール制限"
  assert_contains "$body" "専門知識" "専門知識"
  assert_contains "$body" "敵対的レビュー" "独立レビュー"
}

test_作業の重さと残りの会話期間を判断する() {
  body="$(_skill_text)"
  assert_contains "$body" "残りの会話" "会話期間"
  assert_contains "$body" "次のターンで" "直後に切る場合"
}

test_起動と統合の固定費を判断する() {
  body="$(_skill_text)"
  assert_contains "$body" "起動" "起動費"
  assert_contains "$body" "統合" "統合費"
}

test_起動した結果を必ず回収する() {
  assert_contains "$(_skill_text)" "必ず回収" "結果回収"
}

test_能力帯を役割で選ぶ() {
  body="$(_skill_text)"
  assert_contains "$body" "高能力" "高能力"
  assert_contains "$body" "軽量" "軽量"
  assert_contains "$body" "矛盾" "矛盾発見"
  assert_contains "$body" "機械的" "機械的検査"
}

test_段階4を疎結合の参考情報に限定する() {
  body="$(_skill_text)"
  assert_contains "$body" "参考情報" "段階4との関係"
  assert_contains "$body" "snapshot" "schema非依存"
  assert_contains "$body" "自動変更しない" "自動変更禁止"
}

test_数値とモデル名を普遍化しない() {
  body="$(_skill_text)"
  assert_contains "$body" "直接測定していない" "固定費の限界"
  assert_contains "$body" "固定の損益分岐点" "固定閾値禁止"
  assert_contains "$body" "モデル名" "モデル名非固定"
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh delegation-policy`

Expected: `skills/delegation-policy/SKILL.md`が存在しないため8件がFAILする。

- [ ] **Step 3: 最小の`delegation-policy` skillを実装する**

`skills/delegation-policy/SKILL.md`へfrontmatterと次の見出しを置く。

```markdown
---
name: delegation-policy
description: Use when deciding whether to delegate a heavy investigation, implementation, or review, whether to parallelize work, or which capability tier should own a bounded subtask.
---

# 委譲判断

## 判断順序
## 委譲しない場合
## 能力帯を選ぶ
## 起動前に決める境界
## 結果を回収して統合する
## 段階4の診断との関係
## 数値の限界
```

本文は設計書§4〜6の順序と境界を、省略せず命令形で記述する。出力テンプレートとして「判断、理由、委譲範囲、能力帯、完了条件、回収方法」を含める。

- [ ] **Step 4: skillテストを再実行する**

Run: `bash test/run.sh delegation-policy`

Expected: 8/8 PASS。

- [ ] **Step 5: 件数下限を更新してTask 1をコミットする**

`test/expected-min-count`の総数を`521`、個別下限に`test-delegation-policy.sh 8`を追加する。

```bash
git add skills/delegation-policy/SKILL.md test/test-delegation-policy.sh test/expected-min-count
git commit -m "feat: 段階5の委譲判断スキルを追加"
```

### Task 2: 既存installerの安全契約を実名で固定する

**Files:**
- Modify: `test/test-install.sh`
- Modify: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- install後の`delegation-policy`はリンクまたは所有マーカー付きコピーであり、台帳`skills[].name`と`.gitignore`へ実際に設置した場合だけ記録される。
- 利用者所有の同名ディレクトリは上書き・台帳登録・uninstall削除しない。
- uninstall後の再installで同じskillを再導入できる。

- [ ] **Step 1: installの失敗テストを3件追加する**

`test/test-install.sh`へ次を追加する。

```bash
test_delegation_policyをリンクし台帳とgitignoreへ記録する() {
  _setup_target
  _run_install
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" '"name": "delegation-policy"' "台帳"
  assert_contains "$(cat "$TARGET/.gitignore")" ".claude/skills/delegation-policy" ".gitignore"
}

test_delegation_policyをコピー配置できる() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/.claude-token-saver"
}

test_利用者所有のdelegation_policyを上書きも記録もしない() {
  _setup_target
  mkdir -p "$TARGET/.claude/skills/delegation-policy"
  printf '利用者の方針\n' >"$TARGET/.claude/skills/delegation-policy/SKILL.md"
  _run_install
  assert_contains "$(cat "$TARGET/.claude/skills/delegation-policy/SKILL.md")" "利用者の方針" "同名保護"
  assert_not_contains "$(cat "$TARGET/.token-saver/installed.json")" '"name": "delegation-policy"' "台帳"
}
```

- [ ] **Step 2: uninstallの失敗テストを4件追加する**

`test/test-uninstall.sh`へ、通常リンク削除、`CTS_NO_SYMLINK=1`コピー削除、利用者所有の同名保持、install→uninstall→install再導入の4関数を追加する。各関数は`delegation-policy/SKILL.md`またはディレクトリの存在/不在を直接assertし、既存の`session-handoff`だけを代理にしない。

- [ ] **Step 3: installer対象テストを実行する**

Run: `bash test/run.sh install`

Run: `bash test/run.sh uninstall`

Expected: 既存の`skills/*/`発見だけで、`test-install.sh` 107件と`test-uninstall.sh` 86件がPASSする。実装コード変更は不要である。

- [ ] **Step 4: 件数下限を更新してTask 2をコミットする**

`test/expected-min-count`を総数`528`、`test-install.sh 107`、`test-uninstall.sh 86`へ更新する。

```bash
git add test/test-install.sh test/test-uninstall.sh test/expected-min-count
git commit -m "test: 委譲判断スキルの導入往復を固定"
```

### Task 3: README、基礎設計、移植元切り替え手順を同期する

**Files:**
- Modify: `test/test-delegation-policy.sh`
- Modify: `README.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `test/expected-min-count`

**Interfaces:**
- READMEの状態表は`delegation-policy`を実装済みとする。
- READMEは明示的な読み込み、判断原則、段階4との疎結合、移植元側で別途実施する6段階の切り替えを案内する。
- 基礎設計書§5.4と段階表は実装済みの現在形に更新する。

- [ ] **Step 1: 文書契約の失敗テストを4件追加する**

`test/test-delegation-policy.sh`へ次の観点を追加する。

```bash
test_READMEはdelegation_policyを実装済みと案内する() {
  assert_contains "$(cat "$REPO_ROOT/README.md")" "委譲判断ガイド（delegation-policy） | **実装済み**" "状態表"
}

test_READMEは明示読み込みと判断原則を案内する() {
  body="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$body" "必要なときだけ" "on-demand"
  assert_contains "$body" "必ず回収" "結果回収"
}

test_READMEは移植元を変更せず切り替え手順を示す() {
  body="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$body" "移植元の切り替え" "移行見出し"
  assert_contains "$body" "移植元の運用規約" "別Issue"
  assert_contains "$body" "重複する方針" "重複解消"
}

test_基礎設計は段階1から5を実装済みとする() {
  body="$(cat "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md")"
  assert_contains "$body" "段階1〜5は本リポジトリで実装済み" "段階完了"
  assert_not_contains "$body" "段階5の委譲ガイドは未実装" "旧状態"
}
```

- [ ] **Step 2: 失敗を確認する**

Run: `bash test/run.sh delegation-policy`

Expected: 既存README/基礎設計が未実装表示のため、追加した4件がFAILする。

- [ ] **Step 3: READMEを更新する**

状態表を実装済みにし、導入後の配置例へ`skills/delegation-policy`を加える。「委譲判断ガイド」節には、明示読み込み、設計書§4.2の判断順序、固定閾値を置かない理由、段階4を参考情報に限定する境界を記述する。

「移植元の切り替え」節には設計書§8の6手順を記載し、本PRが移植元を変更しないこと、移植元固有の実測値や秘密情報を公開側へ移さないことを明記する。

- [ ] **Step 4: 基礎設計書を更新する**

§5.4を実装済みの現在形にし、on-demand、判断順序、段階4との疎結合、既存installer再利用を追記する。段階表の段階5を完了とし、直後の文を`段階1〜5は本リポジトリで実装済みである。`へ変更する。

- [ ] **Step 5: 文書テストを再実行する**

Run: `bash test/run.sh delegation-policy`

Expected: 12/12 PASS。

- [ ] **Step 6: 件数下限を更新してTask 3をコミットする**

`test/expected-min-count`を総数`532`、`test-delegation-policy.sh 12`へ更新する。

```bash
git add README.md docs/specs/2026-07-31-claude-token-saver-design.md test/test-delegation-policy.sh test/expected-min-count
git commit -m "docs: 段階5の導入と移植元切り替えを案内"
```

### Task 4: Luna実装結果を対象検証して引き渡す

**Files:**
- Verify only: `skills/delegation-policy/SKILL.md`
- Verify only: `test/test-delegation-policy.sh`
- Verify only: `test/test-install.sh`
- Verify only: `test/test-uninstall.sh`
- Verify only: `README.md`
- Verify only: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Verify only: `test/expected-min-count`

**Interfaces:**
- Lunaは実装コミット、対象テスト結果、変更ファイル一覧、残る懸念をcontrollerへ返す。
- controllerはLunaの自己申告を完了根拠にせず、実diffとテストを独立確認する。

- [ ] **Step 1: Luna側で対象テストを実行する**

Run: `bash test/run.sh delegation-policy`

Run: `bash test/run.sh install`

Run: `bash test/run.sh uninstall`

Expected: 12/12、107/107、86/86 PASS。

- [ ] **Step 2: Luna側で静的検査を実行する**

Run: `git diff --check main...HEAD`

Run: `git status --short`

Expected: diff checkがexit 0。変更は計画対象だけで、保護対象の段階4設計書2件は未追跡のまま無変更である。

- [ ] **Step 3: controllerへ引き渡す**

Lunaは各TaskのコミットSHA、テスト件数、`git diff --stat main...HEAD`、実装上の判断、未解決事項を報告して停止する。PRはcontrollerの検証とfresh Sol review後に、明示的なPR許可を受けてから作成する。

---

## Controller verification and review gate

Lunaの引き渡し後、controllerは次を順に行う。

1. `git diff --stat main...HEAD`と`git diff main...HEAD -- <全変更ファイル>`を読む。
2. `bash test/run.sh delegation-policy`、`bash test/run.sh install`、`bash test/run.sh uninstall`を再実行する。
3. `CTS_NO_SKIP=1 bash test/run.sh`、`bash test/test-python-compatibility.sh`、`bash test/bash32-e2e.sh`、`git diff --check main...HEAD`を実行する。
4. 設計者・実装者の既存文脈に依存しないfresh Sol / Highレビューで、Issue #25、段階4整合、公開API、実diff、テスト証拠を照合する。
5. 指摘があれば同じLuna Max taskへTDD修正を返し、controllerが再検証・fresh reviewを繰り返す。
6. 指摘ゼロでのみbranchをpushし、日本語PRを作成する。マージせずユーザーへ依頼する。

