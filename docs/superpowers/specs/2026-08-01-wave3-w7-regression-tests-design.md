# wave3 W3-7 波1・波2回帰テスト補強の設計

## 背景

波1・波2の実装はマージ済みだが、敵対的レビューで見つかった一部の変異が、既存テストのfixture不足により緑のまま通る余地が残っている。W3-7では実装コードを変更せず、既存の担当テストに、実装を弱めた場合に赤くなる回帰テストを追加する。

## 目的と非目的

目的は次の4点である。

1. `handoff-consume.sh` がpending直下の通常ファイルだけを消費し、サブディレクトリの内容を再帰的に消費しないことを固定する。
2. `handoff-consume.sh` が生きたシンボリックリンクを通常のpending項目として消費し、リンク先の実体を直接移動・破壊しないことを固定する。
3. installの旧パス移行が、ドットで始まるpendingファイルを取りこぼさないことを固定する。
4. uninstallのテスト自身が、installで生成される`settings.local.json`を前提としていることを明示し、installが生成を止めた回帰を無検証で通さない。

`.gitignore`マーカーの前方一致誤認（D1b）は、現行の`test/test-uninstall.sh:test_同じ接頭辞のユーザーのコメント行を誤認しない`が、利用者行を保持したinstall→uninstall往復として既に実証している。重複テストは追加せず、既存テストをW3-7の完了条件に含める。

非目的は次のとおりである。

- `install.sh`、`uninstall.sh`、`scripts/`、`lib/`の実装変更。
- テストランナー、CI、READMEの変更。
- 新しいテストファイルや新しい依存関係の追加。
- 波4以降の追加レビュー項目の先取り。

## 採用案

既存の波別テストへ最小の実データfixtureを追加する。新しいテストファイルを作る案は、テスト台帳と実行件数を同時に変更し、今回の回帰テストの責務を分散させるため採用しない。実装コードへ防御を追加する案は、既に修正済みの挙動を再実装することになり、W3-7の目的から外れる。

各テストは、単に終了コードを見るのではなく、移動前後のファイル種別・内容・配置を確認する。

### B3: サブディレクトリを再帰消費しない

`test/test-handoff-consume.sh`の既存テストへ、`pending/draft/inner.md`を実際に作るfixtureを加える。実行後に`pending/draft/inner.md`が存在し、`consumed/inner.md`が存在しないことを確認する。トップレベルの`a.md`は従来どおり`consumed/a.md`へ移り、後続処理が実行されていることも同時に確認する。

### B5: 生きたsymlinkを一括消費する

`pending/link.md`からテスト用の実ファイルへ向くsymlinkを作る。引数なしの一括消費後、`consumed/link.md`がsymlinkとして存在し、リンク先の実ファイルが同じ内容で残ることを確認する。これにより、リンクを実体化したり、リンク先を直接移動したりする変異を検出する。

### C4: dotfileを旧パスから移行する

`test/test-install.sh`へ、旧パス`$TARGET/.claude/.handoff/pending/.draft.md.swp`を作るテストを追加する。install後に新パスの同名ファイルの内容を確認し、旧パスのファイルが消費されていることを確認する。通常名の移行テストだけでは、globや列挙のdotfile漏れを検出できないためである。

### uninstallのsettings生成前提

`test/test-uninstall.sh:test_残った_settings_は妥当な_JSON_である`で、`_run_install`直後に`settings.local.json`の存在をassertする。その後のuninstall後検査は、既存の「空なら削除される」仕様を維持するため条件付きのままにする。

## テストと検証

実装前に追加テストを現行コードへ適用して対象テストを実行し、テスト記述が誤っていないことを確認する。実装コードは変更しないため、未固定経路の「現行コードで緑になる」状態を確認したうえで、scratch copy内の対象実装を意図的に弱め、各追加テストが赤くなることを確認する。

実装後は次を確認する。

- `bash test/run.sh test/test-handoff-consume.sh`
- `bash test/run.sh test/test-install.sh`
- `bash test/run.sh test/test-uninstall.sh`
- `bash test/run.sh`
- `bash -n test/test-handoff-consume.sh test/test-install.sh test/test-uninstall.sh`
- `git diff --check`

対象差分は次の3ファイルと設計・計画書に限定する。`test/expected-min-count`は実測件数を下回る場合だけ更新する。

- `test/test-handoff-consume.sh`
- `test/test-install.sh`
- `test/test-uninstall.sh`

## 代替案と判断

専用のW3-7テストファイルを作る案は、既存テストとの重複と台帳更新を増やすため不採用とする。D1bのテストを複製する案は、同じマーカー判定を別fixtureで検証するだけで、既存の往復テストを強化しないため不採用とする。実装コードを変更する案は、W3-7を回帰テストの波として分離したIssue #9のスコープに反するため不採用とする。
