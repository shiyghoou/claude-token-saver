# token-saver の管理ディレクトリをルート直下へ移す

作成日: 2026-07-31

`docs/specs/2026-07-31-claude-token-saver-design.md` の一部を改訂する設計である。
段階1（セッション引き継ぎ）の実装を含む PR #1 のマージ前に取り込む。

## 1. 目的

token-saver が管理するデータと状態を `.claude/` 配下から導入先リポジトリの
ルート直下へ移し、Claude Code 以外のエージェント（Codex CLI など）からも
同じ場所を参照できる配置にする。

今回の範囲は**置き場所を共有可能にすることまで**である。Codex 側から
引き継ぎを読み込む仕掛けは実装しない。

## 2. 移せるものと移せないもの

| 対象 | 現在 | 変更後 | 理由 |
|---|---|---|---|
| 引き継ぎデータ | `.claude/.handoff/{pending,consumed}/` | `.token-saver/handoff/{pending,consumed}/` | ツール中立なデータ |
| 台帳 | `.claude/.token-saver/installed.json` | `.token-saver/installed.json` | ツール中立な状態 |
| フック登録 | `.claude/settings.local.json` | **変更なし** | パスは Claude Code が決める |
| スキル本体 | `.claude/skills/session-handoff` | **変更なし** | 同上 |

下2つが動かないため、Codex と実際に連携するには Codex 側にも別途アダプタが
必要になる。今回はそれを作らない。この非対称は README に明記する。

## 3. 配置

```
<導入先>/
  .token-saver/
    handoff/
      pending/
      consumed/
    installed.json
  .claude/
    settings.local.json
    skills/session-handoff
```

`.gitignore` の claude-token-saver ブロックは次の内容になる。

```
.token-saver/
.claude/skills/<設置したスキル名>
```

`.token-saver/` の1行が `handoff/` と `installed.json` の両方を覆う。
スキルの行は従来どおり、実際に設置したものだけを書く（導入先が自前で持って
いるスキルを無視すると、その版管理を静かに壊すため）。

## 4. パスの単一情報源

現在、パス文字列は `install.sh`・`uninstall.sh`・`scripts/lib/common.sh` の
3箇所に散っている。移動のついでに単一情報源へ寄せる。

- `scripts/lib/paths.sh` を新設し、次を定義する。
  - `cts_base_rel`      … `.token-saver`
  - `cts_handoff_rel`   … `.token-saver/handoff`
  - `cts_legacy_handoff_rel` … `.claude/.handoff`
  - `cts_legacy_state_rel`   … `.claude/.token-saver`
- `install.sh` と `uninstall.sh` は `$CTS_HOME/scripts/lib/paths.sh` を source する。
- `scripts/lib/common.sh` は `$SCRIPT_DIR/paths.sh` を source し、
  `cts_handoff_dir` / `cts_state_dir` をこの定義から組み立てる。

`lib/ledger.py` は台帳のパスを引数で受け取るため変更は要らない。位置に言及した
コメントだけ直す。

### 検証（重要）

3巡目のレビューで「同じ定義を2層に書くと両方とも検証できなくなる」という
欠陥が出た。今回は同じ穴を静的ゲートで塞ぐ。

`test/run.sh` に次のゲートを追加する。ゲートは**実装コードだけを対象**とする。

- 対象: `install.sh`、`uninstall.sh`、`scripts/**`、`lib/**`
- 対象外: `scripts/lib/paths.sh` 自身、`test/**`、`docs/**`、`README.md`、`.gitignore`
- 対象ファイルに `.token-saver` または `.claude/.handoff` のリテラルが現れたら赤。
- 実装は `test/run.sh` の冒頭（アサーション層の生存確認の直後）に置き、
  違反があればテストを1本も走らせずに終了コード 1 で打ち切る。1箇所の
  直し忘れが「他は緑だから大丈夫」と読まれる余地を残さないためである。

**テストは対象外にする。これは意図である。** テスト側も `paths.sh` から
パスを導出させると、実装とテストが同じ定義を参照するだけになり、パスが
まるごと間違っていても両者が一致して緑になる（3巡目に出た「同じ検証を
2層に書くと両方とも検証できなくなる」欠陥と同型）。よって**契約テストは
リテラルを直書きする**。ゲートが守るのは実装側の取りこぼしだけである。

ゲートが無ければ、実装の「1箇所直し忘れ」がテスト緑のまま通る。

## 5. 旧パスからの移行

`install.sh` に移行ステップを設ける。**台帳を読む前**に実行する。台帳自身が
移動対象であり、順序そのものが契約になる。

処理:

1. 新パスのディレクトリを作る。
2. `.claude/.handoff/pending/*` を `.token-saver/handoff/pending/` へ移す。
   `consumed` も同様。
3. `.claude/.token-saver/installed.json` を `.token-saver/installed.json` へ移す。
4. 空になった旧ディレクトリだけ `rmdir` する。

制約:

- **新側に同名がある場合は上書きしない。** その1件を旧側に残し、警告に積む。
  引き継ぎは作業の記録であり、失うと事故の調査ができなくなる。
- `mv` で移す。シンボリックリンクは追わず、リンク自体が移る。リンク先の
  検証は従来どおり読み取り時（`scripts/handoff-check.sh`）が担う。
- 旧パスが無い場合は何もしない。警告も出さない（新規導入が普通の経路である）。
- 移行が1件でも起きたら `applied` に積む。黙って動かしてはならない。

## 6. uninstall.sh

- 後片付けの `rmdir` を新パスへ変える。
  `.token-saver/handoff/{pending,consumed}` → `.token-saver/handoff` →
  `.token-saver` の順。`rmdir` は空でなければ何もしないため、実ファイルの
  ある引き継ぎは従来どおり残る。
- **旧パスの台帳を読むフォールバックを追加する。読んでいる間は書き戻さず、
  外し切れたら（警告ゼロなら）その旧台帳を削除する。** これが無いと
  「旧版で install → 新版で uninstall」で台帳が見つからず、fail-closed
  により利用者のフックを残したまま終わる。事故ではないが、外せない状態になる。
  削除するのは、旧台帳が移行元だからである。残すと次回の `install.sh` が
  その古い台帳をまた移行対象として拾ってしまう。
- 引き継ぎ・状態ファイルを残したときの案内文のパスを新パスへ直す。
- `rmdir "$TARGET/.claude"` は維持する。スキルを外して空になれば消える。

## 7. テスト

- 既存 246 件のうちパスを期待値に持つものを更新する。
  `test/expected-min-count` の総件数とファイル別件数も一緒に上げる。
- 新規に加えるもの:
  - 移行: 正常系／新側と衝突／シンボリックリンク／旧パスなし／旧が空
  - パスの単一情報源ゲート（§4）
  - uninstall の旧台帳フォールバック
- **各項目にミューテーションでの実証を課す。** 修正箇所を壊したときに、
  その項目のテストが赤になることを確認する。3巡目で導入した規律を継続する。
- `test/bash32-e2e.sh` を新パスで実機確認する（CI の `bash32` ジョブ）。

## 8. README に明記すること

- `.token-saver/` はツール中立な置き場所である。**Codex 側から読み込む仕掛けは
  別段階であり、今回は Codex は自動では読まない。**
- リポジトリ名 `claude-token-saver` とディレクトリ名 `.token-saver` の不一致は
  意図的である（ツール中立化の一歩）。
- 旧パスからの移行は `install.sh` が行う。手動移行は要らない。

## 9. 影響と限界

- 導入先リポジトリのルートに `.token-saver/` が1つ増える。ドット付きなので
  通常のファイル一覧には現れない。
- Claude Code 固有の2つ（フック登録・スキル本体）は `.claude/` に残るため、
  「すべてがルート直下に集まる」わけではない。
- 段階2以降（計測エンジン移植）のレポート出力先も `.token-saver/` 配下へ
  置くのが自然になる。既存設計書 §5.2 の一般化点をその方向で読み替える。
