# Issue #56: オートモード補助エージェント計測 設計

- 作成日: 2026-08-08
- 対象Issue: #56
- 状態: 設計承認済み

## 1. 目的

オートモードを有効にしたセッションでは、利用者が依頼した本来の処理とは別に、安全性やレビューのためのモデル呼び出しが走る。ところが、現行の `token-report` が分けているのは main session と通常 subagent までであり、この補助処理は独立した区分になっていない。

本Issueでは、次の2種類を **オートモード補助エージェント** として別枠で可視化する。

- Claude Code の auto mode が使う permission classifier
- Codex の guardian subagent が使う `codex-auto-review`

ただし、両環境のログに同じ情報が残るわけではない。Codex は usage を実測できる一方、Claude Code の transcript から確認できるのは classifier の呼出しだけである。この差を推計で埋めず、観測できた事実と計測不能を同じレポートで明示する。

既存契約である main session と通常 subagent の分離は維持する。オートモード補助エージェントの値を、どちらの合計にも混ぜない。

## 2. 観測できるデータと限界

### 2.1 Claude Code

auto mode の permission classifier が判断した tool result には `classifierMetaLines` が記録される。親セッションと subagent の双方で観測でき、各行には一意な `uuid` も通常含まれる。

一方、同じ行の `message.usage` と `toolUseResult.usage` は classifier 固有の usage を持たない。`classifierMetaLines` の長さや main session の usage 差分を代理にしても、入力コンテキスト、キャッシュ、並列判断を分離できない。

したがって Claude Code では、呼出回数だけを実測し、トークン数を `N/A` とする。`0` とは表示しない。ゼロ消費ではなく、ログから計測できないためである。

### 2.2 Codex

Codex の auto review は独立した session JSONL として残り、観測済みのログでは次の属性を持つ。

- `session_meta.source.subagent.other == "guardian"`
- 対応ターンの `turn_context.model == "codex-auto-review"`
- `event_msg` の `payload.type == "token_count"`
- `payload.info.last_token_usage` にターン単位の usage がある

この組合せなら、main task の通常モデル呼び出しと auto review を分けられる。ただし、これは公開された永続スキーマではない。属性欠落や型変更が起きた場合は推測分類せず、分類不能または usage 欠測として扱う。

## 3. 採用する方式

既存の `scripts/measure-token-usage.py` に、main / subagent 集計から独立した `auto_auxiliary` 集計を追加する。レポート生成まで同じプロセスで完結させ、daemon、hook、gateway、外部データベースは増やさない。

データの流れは次のとおりである。

1. 既存の Claude project 選択で親 JSONL と `subagents/*.jsonl` を決める。
2. Claude JSONL から permission classifier の呼出しを重複排除して数える。
3. `CODEX_HOME/sessions/**/*.jsonl` を読み、Codex guardian / auto-review の期間内 usage を集計する。
4. main、通常 subagent、オートモード補助エージェントを別々の値として Markdown に出す。

`CODEX_HOME` が未設定なら `~/.codex` を使う。複数の推測ディレクトリを横断せず、利用者が選んだ Codex home の境界を守る。

## 4. Claude permission classifier の集計契約

### 4.1 対象行

選択済み project の親・subagent JSONLにある、空でない `classifierMetaLines` を持つ user 行を対象とする。`classifierMetaLines` の内容は分類にもレポートにも使わない。

### 4.2 重複排除

安全な scalar `uuid` がある場合は、それを project 内の主キーにする。同一イベントが複数の入力経路に現れても一度だけ数える。

`uuid` が無い場合だけ、`sessionId`、`sourceToolAssistantUUID`、tool result content block の `tool_use_id` がすべて安全な scalar のとき、その3値のtupleを代替キーにする。1値でも欠ける行は推測でまとめず、識別子欠測として数える。

### 4.3 期間とrepo

- `--days N` は行の timestamp に適用する。
- timestamp が無い行は、`--days 0` の全期間指定時だけ採用できる設計にはしない。期間帰属を証明できないため常に欠測扱いとする。
- 既定では現在のrepoに対応する Claude projectだけを読む。
- `--all-projects` のときだけ全projectへ広げる。

### 4.4 出力

少なくとも次を示す。

- classifier 呼出数
- 識別子欠測数
- timestamp 欠測数
- usage 実測: `N/A`
- transcript に classifier 固有 usage が無いため推計しない、という注意

## 5. Codex auto review の集計契約

### 5.1 session とターンの識別

session 全体を auto review と決め打ちせず、次を順に確認する。

1. `session_meta.source` が object である。
2. `session_meta.source.subagent.other` が厳密に `guardian` である。
3. 直前に確認した `turn_context.model` が厳密に `codex-auto-review` である。
4. 後続の `token_count.info.last_token_usage` が安全な非負整数だけを持つ。

guardian だけ、または model だけが一致しても採用しない。将来の別用途セッションや同名モデルを誤って混ぜるより、欠測を明示する方を優先する。

### 5.2 usage フィールド

主合計は次の2値で作る。

```text
total = input_tokens + output_tokens
```

次の値は内数として別に表示し、totalへ足し直さない。

- `cached_input_tokens` は input の内数
- `reasoning_output_tokens` は output の内数

`cache_write_input_tokens` は内訳として保持できるが、観測済みの `total_tokens` 契約と一致することを検証し、主合計へ独自加算しない。usage object の `total_tokens` と `input_tokens + output_tokens` が一致しない場合は、そのイベントを不整合として除外する。

### 5.3 重複排除

同一 session 内で累積 `total_token_usage` の安全なtupleが再掲された場合は、同じ応答の再記録とみなし `last_token_usage` を二重加算しない。

session ID は内部キーにのみ使う。レポートへ出さない。安全な session ID が無い場合はファイル単位の内部識別子を使うが、実パスもレポートへ出さない。

### 5.4 期間とrepo

- `--days N` は各 `token_count` の timestamp に適用する。
- 期間境界をまたぐsessionでも、期間内の `last_token_usage` だけを採用する。最終累積値を丸ごと期間へ入れない。
- 既定では、`session_meta.cwd` が現在のGit rootと一致するか、その配下にあるsessionだけを対象にする。
- `--all-projects` のときは cwd によるrepo絞り込みを外す。
- cwd が無い、型が違う、または安全に正規化できないsessionは既定集計へ入れない。

### 5.5 出力

少なくとも次を示す。

- guardian session 数
- usage を取得できた auto-review ターン数
- input / cached input（内数）/ output / reasoning output（内数）/ 合計
- guardianだがmodel不一致のsessionまたはターン数
- auto-reviewだがusage欠測・型不正・total不整合だった件数

## 6. レポート構成

既存レポートへ次の独立節を追加する。

```text
## オートモード補助エージェント

### Claude Code permission classifier
- 呼出: N 件
- usage実測: N/A
- 注意: transcriptにclassifier固有usageが無いため、欠測分は推計しない。

### Codex auto review
- guardian session: N
- usage取得ターン: N

| input | cached input（内数） | output | reasoning output（内数） | 合計 |
| ...   | ...                 | ...    | ...                       | ...  |
```

この節は main / subagent の「実測合計」とは別枠に置く。3区分を合算した請求総額や節約額は出さない。

Codex履歴ディレクトリが無い場合も、Claude側のレポート生成は成功させる。その場合は「Codex履歴なし」と表示する。存在するが読めない場合は同じ扱いにせず、「Codex履歴を読めない」と警告する。

## 7. 秘密情報と安全境界

追加集計でも既存の共有境界を維持する。

含めてよいもの:

- 集計値
- 固定識別名 `guardian` / `codex-auto-review`
- 欠測・除外件数

含めないもの:

- `classifierMetaLines` の本文
- prompt、content、tool result本文
- session ID、turn ID、request ID
- Codex homeやsession JSONLの実パス
- repo外の cwd
- 環境変数や認証情報

通常レポートはread-onlyである。入力JSONL、Claude/Codex設定、hook、gateway、calibration snapshotを書き換えない。

## 8. calibration との境界

オートモード補助エージェントは通常レポートの参考情報に限る。

- calibration snapshotへ新しいフィールドを追加しない。
- fingerprint の入力へ追加しない。
- 推奨閾値の算出へ使わない。
- `token-calibrate --apply` の更新対象を増やさない。
- オート補助usageを根拠に設定やpermission modeを自動変更しない。

これにより、Codex履歴の有無や `CODEX_HOME` の違いが既存snapshotの再現性を変えない。

## 9. エラー処理

次の入力はトレースバックを出さず、該当区分だけを欠測・除外として扱う。

- 壊れたJSONL
- objectであるべき値の型違い
- 負数、真偽値、小数、文字列のtoken値
- timestamp欠落または不正
- 非単調または再掲された累積usage
- guardian / model / cwd の識別条件不足

ただし、レポート出力先の安全性、atomic配置、明示された入力rootの重大なアクセス失敗は既存のfail-closed契約を維持する。Codexが任意入力源であることを理由に、既存レポート全体の安全境界を緩めない。

## 10. テスト設計

実ホームに依存しない合成fixtureで検証する。

### 10.1 Claude Code

1. 親JSONLの `classifierMetaLines` を1呼出として数える。
2. subagent JSONLのclassifierも同じ区分へ数える。
3. 同じ `uuid` の再掲を一度だけ数える。
4. `uuid` / timestamp欠測を所定の欠測件数へ入れる。
5. usageを `0` や代理値にせず `N/A` と表示する。
6. `classifierMetaLines` の秘密文字列をレポートへ出さない。

### 10.2 Codex

1. guardianと`codex-auto-review`の両方が一致したターンだけを集計する。
2. 非guardianの同名modelを除外する。
3. guardianの別modelを除外する。
4. repo外と期間外のusageを除外する。
5. `last_token_usage` を期間内で合計する。
6. 同じ累積usageの再掲を二重加算しない。
7. cached inputとreasoning outputを主合計へ足し直さない。
8. total不整合、型不正、usage欠測を除外件数へ入れる。
9. `CODEX_HOME` 指定先を読み、未設定時は `~/.codex` を使う。
10. 履歴なしと履歴読取不能を区別する。
11. Codexの会話本文、ID、実パスをレポートへ出さない。

### 10.3 回帰

1. main / 通常subagentの既存合計が変わらない。
2. calibration snapshot / fingerprint / 推奨値が変わらない。
3. `--days` / repo選択 / `--all-projects` の既存意味を維持する。
4. Python 3.6互換性スモークが通る。
5. 関連個別テストと可能な範囲の `test/run.sh` が通る。
6. `git diff --no-renames --check` が通る。

## 11. 変更ファイル

- Modify: `scripts/measure-token-usage.py`
- Modify: `test/test-token-report.sh`
- Modify: `test/test-token-report-docs.sh`
- Modify: `test/python-compatibility.py`（必要な構文境界を追加する場合）
- Modify: `test/expected-min-count`
- Modify: `README.md`
- Modify: `skills/token-report/SKILL.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`

launcher、installer、hook、calibration適用コードは、必要性がテストで証明されない限り変更しない。

## 12. 非目標

- LLM Gateway、HTTP proxy、TLS終端proxyの導入
- Claude Codeの認証・課金・通信経路の変更
- `--permission-prompt-tool` によるClaude auto modeの置換
- classifier本文長、main usage差分、ネットワークbytesによるtoken推計
- Claude/Codex本体や保存形式の変更要求
- main / subagent / auto補助を単一の請求合計へ統合すること
- オート補助usageを使った設定自動変更

## 13. 後続調査候補

Claude Codeは[公式のLLM Gateway設定](https://docs.anthropic.com/en/docs/claude-code/llm-gateway)を使ってusage trackingを構成できる。しかし、全API usageからpermission classifier要求だけを安定して識別する公式タグは確認できていない。通常の[corporate proxy設定](https://docs.anthropic.com/en/docs/claude-code/corporate-proxy)だけでは、TLS越しの通信bytesを正確なtoken数へ変換できない。

別Issue候補では、実利用環境の認証・課金経路を変更せず、次を先に検証する。

1. auto modeのclassifier要求がgatewayを通るか。
2. main要求とclassifier要求を区別する安定したmetadataがあるか。
3. 並列tool callとprompt cacheを含めても対応付けが一意になるか。
4. Pro / Max OAuth利用とgateway利用の契約が両立するか。

この4点が確認できない限り、gateway集計を本レポートの「実測」へ昇格させない。

## 14. 受け入れ条件

- Claude Code permission classifierの呼出数が親・subagentを通じて重複なく表示される。
- Claude側のtokenは `N/A` と理由が表示され、推計値やゼロで埋められない。
- Codex guardian / `codex-auto-review` の期間内usageだけが実測表示される。
- cached input / reasoning outputの内数を二重加算しない。
- 識別条件不足、型不正、欠測、壊れたJSONLを隠さず、推計補完しない。
- main / 通常subagent合計、calibration snapshot、fingerprint、閾値適用が変わらない。
- 秘密情報とrepo外パスがレポートへ漏れない。
- README、token-report skill、基礎設計書が本契約と一致する。
- 関連個別テスト、Python互換テスト、可能な範囲の全件ランナー、diff checkが成功する。

オートモードの補助処理は、見えないからゼロなのではない。Codexでは実測し、Claude Codeでは計測不能を計測不能のまま示す。この区別を崩さないことが、本Issueの完了条件である。
