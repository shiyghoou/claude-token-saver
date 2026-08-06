# Issue #42: サブエージェント消費の subagents/*.jsonl 実測 設計

- 作成日: 2026-08-06
- 対象Issue: #42
- 状態: 設計承認済み

## 1. 目的

1. サブエージェントのトークン消費を、親セッションの `toolUseResult.totalTokens` ではなく **`subagents/*.jsonl` の `message.usage`** から実測する。
2. 欠測やカバレッジ不足を隠さず、不完全な集合を母集団全体であるかのように見せない。
3. 起動固定コストを各サブエージェントログから実測し、README / `delegation-policy` の「未測定」文言を環境固有の参考値として置き換える。

既存契約「main と subagent の usage を別枠で見る」は維持する。

## 2. 根本原因

現行の `measure-token-usage.py` はサブエージェント消費を親 JSONL の `toolUseResult.totalTokens` から集計している。この値は**同期起動で結果を回収したときだけ**書かれる。

書かれない主なケース:

- `run_in_background: true` の非同期起動
- エラー終了・ユーザー中断
- 結果回収前にターンが終わった起動

実導入先の30日集計では、起動 256 回のうち結果付きは 76 回（約30%）、`totalTokens` 合計は約 610 万で main 比 0.19% だった。一方、同期間・同環境で `subagents/*.jsonl` の `message.usage` を重複排除集計すると約 3.85 億トークン（現行値の約63倍）であり、main と合わせると全体の約10.6%を占める。現状のレポートは委譲判断を歪める。

加えて README / スキルは起動固定費を「直接測定していない」とし、メイン開始中央値を代理にしている。各サブログの**最初の assistant ターン入力**で直接測れる。

## 3. 採用する方式

利用者確認済みの推奨案（いずれも案 A）に従う。

### 3.1 消費源（案 A）

サブエージェントの**消費合計の唯一の源泉**は `*/subagents/**/*.jsonl` の `assistant` 行 `message.usage` とする。

- 集計フィールドは main と同じ: `input_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens`
- 重複排除も main と同じ: `message.id`、無い場合は代替キー
- **`toolUseResult.totalTokens` は消費合計に使わない**（併存・加算・クロスチェック加算もしない）
- `toolUseResult.usage` があっても jsonl 側と二重に足さない

背景起動でもログが残る限り消費を拾える。既存 fixture の「12345」依存テストは新契約へ書き換える。

### 3.2 カバレッジと欠測（案 A）

期間内のサブエージェント母集団は、親の Agent 起動と残存ログの両方で不完全になり得る（保持期間・命名・親セッション切り捨て）。

そのためレポートは必ず次を明示する。

- 親側から見た期間内**起動数**
- 期間内に読めた **subagents ログ本数**（および usage 行を持つ本数）
- 起動に紐づくログが見つからない件数、または起動側に現れない孤立ログ件数（分かれば）
- 「この区間の完全母集団ではない」旨の短い注意

**欠測分を平均値で埋めない。** 比率（main 比など）は、実測できた usage に対する値だとわかる表記にする。不完全集合を全体の代理として断定しない。

Claude Code のログ保持ポリシー変更自体は本Issueのスコープ外とする（§8）。

### 3.3 型の解決と `(不明)`（案 A）

`subagent_type` 付きの行は、親 JSONL の Agent `tool_use`（および必要なら結果）が持つ **agentId ↔ type** の対応で、サブログへ属性付けしたあとだけとする。

- ファイル名やエントリ上の agentId と親側の対応が取れた場合だけ、その type で分類する
- 対応が取れないログ・起動はバケツ **`(不明)`** に入れる
- `(既定)` は親の `subagent_type` 欠落時の既存意味を維持し、未解決 join とは区別する

型別表に載る type 名は、上記 join 後の値と `(不明)` / `(既定)` に限る。推測補完はしない。

### 3.4 `delegation-policy` 文言（案 A）

固定の普遍的閾値・モデル名・価格は引き続き置かない。文言を次の趣旨へ更新する。

- token-report が出す**起動固定コストの実測値**を、その環境・期間の参考として使ってよい
- それでも普遍の損益分岐点やモデル名・価格規則にはしない

README の「固定コストは直接測定していない／メイン開始中央値を代理」も同趣旨で差し替える。

## 4. 集計契約

### 4.1 main との分離（既存契約の維持）

- `subagents/` 配下の `message.usage` は **main 合計へ混ぜない**
- 親の Agent 呼び出しにかかる親自身の `message.usage` は従来どおり main に残す
- レポート上の「実測合計」は main と sub を別枠で示し、合算する場合は別枠合算であることが分かる見出しにする

### 4.2 起動数

期間内の起動数は、親 JSONL の Agent `tool_use` から数える（現行の `agent_calls` 系）。消費合計の源泉切り替え後も起動数の定義は変えない。

### 4.3 起動固定コスト

各 `subagents/*.jsonl` について、期間フィルタ適用後に残る行のうち、**最初の `assistant` かつ `message.usage` 付きターン**の入力トークンを起動固定コストとする。

```text
fixed = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
```

レポートに少なくとも次を出す。

- 中央値 / 最小 / 最大 / 標本数（対象ログ本数）

**固定コストは消費合計へ二重加算しない。** 初回ターンの usage はすでに sub 合計に含まれる。固定コストは診断・委譲判断用の分布指標である。

### 4.4 型別表

`subagent_type`（および `(不明)` / `(既定)`）ごとに少なくとも次を出す。

| 列 | 意味 |
| --- | --- |
| 起動 | 親 Agent `tool_use` 由来の起動数 |
| ログ | その type に属性付けできた subagents ログ本数 |
| usage 合計（内訳可） | 当該ログの `message.usage` 集計 |

並べ替えは消費または起動の多い順など既存表の慣習に合わせ、`--top` で制限する。

### 4.5 二重計上ポリシー（6規則）

1. **main 排他:** `subagents/**/*.jsonl` の usage を main 合計へ入れない。
2. **sub 源泉単一:** sub の消費合計は `message.usage` のみ。`toolUseResult.totalTokens` も `toolUseResult.usage` も合計へ入れない。
3. **親の Agent コスト:** 親が Agent を呼んだ自身の assistant usage は main に残し、sub から差し引かない。
4. **固定コスト非加算:** 起動固定コスト指標を sub / main / 合算のトークン合計へ足し直さない。
5. **側内重複排除:** main / sub それぞれで `message.id`（または代替キー）による重複排除を行い、content ブロック分割で二重加算しない。
6. **側間 ID 非結合:** main と sub で同じ `message.id` があっても相互に加算・相殺しない。別セッション空間として扱う。

## 5. レポートと文書の見せ方

### 5.1 token-report 本文

- サブエージェント節の主指標を「`message.usage` 実測」へ切り替える
- `toolUseResult.totalTokens` を主合計として載せない（節見出し・診断文からも消費の根拠にしない）
- カバレッジ（起動数 / ログ本数 / 欠測の注意）を同じ節に置く
- 起動固定コストの中央値・最小・最大・標本数を出す
- 型別表（起動 / ログ / usage）を出す
- 秘密情報境界は維持（prompt・本文・tool result content は出さない）

### 5.2 calibrate 診断

段階4診断の「サブエージェント利用」は、本契約の実測 usage・カバレッジ・固定コストに追随する。`totalTokens` あり／なしの区別を主軸にした説明はやめる。

### 5.3 文書

- `README.md` — 見られるもの・限界節の固定コスト／sub 計測説明
- `skills/token-report/SKILL.md` — 読み方と限界
- `skills/delegation-policy/SKILL.md` — §3.4 の文言
- 基礎設計書の該当箇条書き（起動固定費未測定、`totalTokens` 前提）を整合

## 6. テスト設計

既存の `test/test-token-report.sh`（および診断に触れる場合は calibration 系）へ TDD で追加・更新する。実ホームに依存しない合成 fixture を使う。

1. **sub usage 実測:** `subagents/*.jsonl` の `message.usage` がサブ別枠合計に現れ、期待値と一致する。
2. **main 非混入:** 上記 usage が main 合計へ入らない（既存二重計上アサーションの更新）。
3. **totalTokens 非採用:** 親の `toolUseResult.totalTokens`（および併記 usage）を足しても sub 合計が変わらない。旧「12,345」主合計依存を削除または反転する。
4. **sub 内重複排除:** 同一 `message.id` の複数行が一度だけ加算される。
5. **起動固定コスト:** 初回 assistant 入力の中央値・最小・最大・標本数が期待どおり。合計トークンへ固定コストを足した値にはならないこと。
6. **カバレッジ表示:** 起動あり・ログなし、またはログあり・型未解決の fixture で、カバレッジ／注意文が出ること。欠測を埋めた偽合計にならないこと。
7. **型 join と `(不明)`:** 親 agentId↔type で紐づくものは typed 行に入り、紐づかないログは `(不明)` に入る。
8. **起動数:** 親 Agent `tool_use` の件数が型別「起動」列と一致する。
9. **秘匿:** sub ログ本文・親 tool result の秘密文字列がレポートへ出ない（既存境界テストの回帰）。
10. **文書契約:** README / delegation-policy / token-report スキルから「固定コスト未測定」「totalTokens を主指標とする」旨が消え、環境固有参考の文言になっていること（既存の文書契約テスト様式に合わせる）。

## 7. 変更ファイル

- Modify: `scripts/measure-token-usage.py` — subagents usage 集計、固定コスト、カバレッジ、型 join、レポート／診断出力。`totalTokens` 合計経路の除去
- Modify: `test/test-token-report.sh` — fixture とアサーションの新契約化
- Modify: `test/test-calibration.sh` および／または診断関連テスト（Agent 節が変わる場合）
- Modify: `README.md`
- Modify: `skills/token-report/SKILL.md`
- Modify: `skills/delegation-policy/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`（該当限界・集計記述）
- Modify: `test/expected-min-count`（テスト件数台帳）

Wave 5 設計書への後追い追記は任意とし、本Issueの必須成果物ではない。

## 8. 非目標

- Issue #41（キャリブレーション推奨のパーセンタイル化）
- Codex 側のメータリングや `codex-delegation-policy` の数値差し替え
- `cache_read` などへの課金ウェイト適用・価格表の埋め込み
- Claude Code 本体のサブエージェントログ保持期間・保存場所の変更要求や実装
- 普遍的な損益分岐トークン数、モデル名、価格のスキル埋め込み
- main / sub を単一の「請求合計」APIとして外部統合すること
- 本設計の実装計画書作成（利用者レビュー後の別ステップ）

## 9. 互換性

- レポートのサブエージェント主指標と関連テスト期待値は破壊的に変わる（正しい実測への修正）
- CLI フラグ、`.token-saver/` レイアウト、calibration snapshot の指紋アルゴリズム、設定 JSON の自動変更禁止は変えない
- 公開フィールドを増やす場合も、秘密情報を含むパスや本文は出さない

## 10. 受け入れ条件

- サブエージェント消費の主合計が `subagents/*.jsonl` の `message.usage` のみから得られる
- main へ sub usage が混ざらず、固定コストの二重加算もない
- カバレッジ／欠測がレポート上で見え、不完全集合を全体と誤解させない
- 型付けは join 成功時のみ。それ以外は `(不明)`
- 起動固定コストの中央値・最小・最大・標本数がレポートに出る
- README / token-report / delegation-policy が「環境固有の実測参考・普遍閾値なし」と整合する
- §6 のテストと既存全件ランナーが通る
- 実装計画・実装・push は本設計承認後の別作業とする
