# Issue #29: delegation-policy の Codex 対応 設計

## 1. 目的

Claude Code 向けに実装した `delegation-policy` を、既存の `install.sh` だけで
Codex のリポジトリスキルとしても安全に導入・明示実行できるようにする。

既存の Claude Code 側の配置、フック、CLI、台帳 schema は維持する。Codex 対応を
宣言したスキルだけを `.agents/skills` に追加配置し、Claude Code 固有の既存スキルを
無条件に Codex へ露出しない。

## 2. 公式仕様と現状の差分

Codex の公式スキル仕様では次が定義されている。

- リポジトリスキルは、現在ディレクトリからリポジトリルートまでの
  `.agents/skills` から探索される。
- スキルは `SKILL.md` の `name` と `description` を必須とする。
- Codex CLI / IDE では `$skill-name` または `/skills` から明示実行できる。
- `agents/openai.yaml` の `policy.allow_implicit_invocation: false` で暗黙起動を
  禁止できる。
- symlink されたスキルディレクトリも探索される。

参照: <https://learn.chatgpt.com/docs/build-skills>

現在の `delegation-policy` は `name`、trigger-only の `description`、instruction-only
の本文を持ち、内容自体は Codex でも利用できる。一方で、`install.sh` は
`.claude/skills` だけへ配置し、明示起動だけという契約も Codex metadata へ固定して
いない。このため現在の導入先では Codex がスキルを発見できず、手動配置した場合は
意図しない暗黙起動も起こり得る。

## 3. スコープ

### 含むもの

1. `delegation-policy` への Codex metadata の追加
2. 既存 installer / uninstaller による `.agents/skills` の安全な往復
3. Codex 側の link、copy、同名保護、symlink 親拒否、gitignore 契約
4. README と基礎設計書の Codex 利用手順・対応範囲の更新
5. contract test、全体回帰、実 Codex の明示呼び出し smoke

### 含まないもの

- Codex 用フックや自動起動処理
- `session-handoff` の Codex 側自動消費
- `token-report` による Codex 使用量計測
- `delegation-policy` 以外の既存スキルの Codex 対応
- plugin / marketplace 化
- モデル名や固定トークン閾値の追加

## 4. Codex 対応スキルの宣言

`skills/<name>/agents/openai.yaml` が存在することを、このリポジトリ内で
「Codex にも配置するスキル」の宣言として扱う。公式 metadata をそのまま opt-in
境界に使い、スキル名のハードコードや別 manifest は追加しない。

今回追加する metadata は最小限にする。

```yaml
policy:
  allow_implicit_invocation: false
```

これにより `delegation-policy` は Codex でも暗黙発火せず、利用者が
`$delegation-policy` を指定した場合だけ明示的に読み込まれる。UI 用の表示名、icon、
default prompt、MCP dependency は不要なので追加しない。

## 5. install のデータフロー

既存の引数と scope は変更しない。引数無しまたは `--personal` で行う personal 配置に
Codex スキルを含め、`--shared` 単独では既存どおり個人スキルを新規配置しない。

1. 既存処理で全 `skills/*/` を `.claude/skills/<name>` へ安全に配置する。
2. source に `agents/openai.yaml` がある場合だけ、同じ source を
   `.agents/skills/<name>` へも配置する。
3. 通常は source への symlink、`CTS_NO_SYMLINK=1` または symlink 作成失敗時は
   `.claude-token-saver` marker 付き copy とする。
4. `.agents` または `.agents/skills` が symlink なら、外部へ追従せず install 全体を
   変更前に失敗させる。
5. 同名の通常ファイル、利用者所有ディレクトリ、別 source を向く link がある場合は
   警告して触らない。
6. `.gitignore` へは実際に配置できた Codex スキルだけを
   `.agents/skills/<name>` として記録する。

Claude Code 側のスキル配置に成功し Codex 側だけが同名衝突で配置されなかった場合、
install 自体は既存契約どおり警告付きで完了する。Codex 側の path は gitignore へ
追加しない。

## 6. 台帳と uninstall の安全境界

`installed.json` の `skills[]` は既存どおり `name`、`src`、`mode` を持つ。Codex 用の
別 schema や追加 field は導入しない。

uninstall は台帳のスキル名を入口にするが、`.claude` と `.agents` の各 destination を
別々に検証する。

- link は記録済み `src` と `readlink` が完全一致するときだけ削除する。
- copy は destination 内の `.claude-token-saver` marker があるときだけ削除する。
- Codex destination は、記録済み source に `agents/openai.yaml` がある場合だけ通常の
  削除候補にする。
- metadata が消えた、source が不明、destination が差し替えられた、または所有権を
  証明できない場合は削除せず警告する。
- 台帳が無い場合は、既定で `.agents/skills` を推測削除しない。

Codex 側と Claude Code 側で link/copy mode が異なり得るため、Codex destination の
削除判断には台帳の単一 `mode` を使わず、実際の file type と所有 marker を使う。
これにより台帳 schema を変えずに fail-closed を保つ。

## 7. skill 本文と呼び出し契約

`SKILL.md` の判断原則は runtime 非依存なので変更を最小限にする。特定の Codex tool
名、Claude Code tool 名、モデル名は埋め込まない。

README では次を明示する。

- Claude Code は `.claude/skills/delegation-policy` を使う。
- Codex は `.agents/skills/delegation-policy` を探索する。
- Codex CLI / IDE では `$delegation-policy` で明示実行でき、`/skills` で一覧を確認
  できる。
- 暗黙起動は禁止されている。
- Codex 対応は委譲判断スキルに限定され、Claude Code のフック、handoff 自動消費、
  token-report 計測まで対応したことを意味しない。

## 8. テスト戦略

### RED / GREEN contract tests

1. metadata と明示起動 policy
2. 通常 install の `.agents/skills/delegation-policy` link
3. `CTS_NO_SYMLINK=1` の marker 付き copy
4. 利用者所有の同名 directory / link / file の保護
5. `.agents` と `.agents/skills` の symlink 親拒否
6. 実際に配置した場合だけの gitignore 行
7. uninstall の link / copy 削除、差し替え保持、台帳無し fail-closed
8. install → uninstall → install の再導入
9. README / 基礎設計の Codex 対応範囲

`test/expected-min-count` は実測した最終件数へ同期する。

### broad verification

- `CTS_NO_SKIP=1 bash test/run.sh`
- `bash test/test-python-compatibility.sh`
- `bash test/bash32-e2e.sh`
- `git diff --check main...HEAD`

### 実 Codex smoke

一時 Git repository へ `install.sh` を実行し、`.agents/skills/delegation-policy` が
配置された状態で installed Codex CLI を bounded に起動する。`$delegation-policy` を
明示し、判断出力の6 fieldを返す短い scenarioを実行する。これは認証・model・network
に依存するため通常 CI へは入れず、PR の検証証拠として結果を記録する。

## 9. エラー処理

- managed parent symlink は変更前に非0で拒否する。
- 同名衝突は利用者所有物を残して警告する。
- copy、台帳、gitignore の更新失敗は既存の strict / warning 契約を維持する。
- Codex がインストールされていない環境でも repository install は成功する。
  installer は Codex binary の存在を前提にしない。
- 実 Codex smoke が環境理由で実行不能なら、contract test の成功と分けて blocker を
  報告し、成功したと偽らない。

## 10. 公開APIと互換性

変更しないもの:

- `install.sh [--personal|--shared] [target]`
- `uninstall.sh [--personal|--shared] [--guess] [target]`
- `CTS_NO_SYMLINK` / `CTS_STRICT`
- `.token-saver/installed.json` schema
- Claude Code の settings / hook / skill 配置
- token-report / calibration / session-handoff の出力と状態

追加される観測可能な動作は、personal install が Codex 対応 metadata を持つスキルを
`.agents/skills` にも安全に配置することだけである。

## 11. 受入条件との対応

| 受入条件 | 対応 |
| --- | --- |
| Codex がスキルを発見できる | `.agents/skills` へ既定配置する |
| 明示起動だけに限定する | `allow_implicit_invocation: false` を検査する |
| Claude Code を壊さない | 既存 `.claude` 処理とCLI/schemaを維持する |
| 利用者所有物を壊さない | link target / marker / ledger を三重に検証する |
| 段階4と不整合を起こさない | skill本文と診断の疎結合を変更しない |
| 実際に動く | contract、全体回帰、実Codex smokeを通す |
