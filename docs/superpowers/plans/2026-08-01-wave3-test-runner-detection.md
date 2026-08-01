# wave3 テストランナー検出力強化の実装計画

> Issue: #7
> ブランチ: `issue-7-wave3-test-runner-detection`
> 設計書: `docs/superpowers/specs/2026-08-01-wave3-test-runner-detection-design.md`

## 実装方針

既存の依存ゼロのBash/AWK/grep実装を維持する。各変更は、先に`test/test-runner-selftest.sh`へ最小の失敗ケースを追加し、現在の実装で期待どおり赤くなることを確認してから、`test/run.sh`または`test/lib/assert.sh`を最小限変更する。各項目を緑にした後、重複した検査処理を整理する。

自己テストの生成本文では、W3-1の「展開を含むアサーション」規則に合わせ、健全なfixtureを変数またはコマンド出力を伴う形にする。静的ゲートそのものを検証するfixtureには、検証対象のコードが実行時にだけ現れる既存の`@A@`置換を継続して使う。

## 作業手順

### 1. ベースラインとカウントの記録

対象ブランチが`origin/main`由来であること、設計コミット以外の変更がないことを確認する。次を実行して、現行の全テスト件数・root環境のskip候補・構文検査結果を記録する。

```bash
bash test/run.sh
bash -n test/run.sh test/lib/assert.sh test/test-runner-selftest.sh
git diff --check
```

### 2. W3-4: 空needle guard（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/lib/assert.sh`。

1. `assert_contains` と `assert_not_contains` に空needleを渡した場合、終了コード1になる自己テストを追加する。
2. 現行実装で自己テストが失敗し、空needleがシェルのワイルドカードとして全体一致することを確認する。
3. 両関数へ`assert_count`と同じ空needle guardを追加する。
4. `_check_assert_layer`相当の素の終了コードプローブを追加し、アサーション層のguard改変を自己検出できるようにする。
5. 対象自己テストと全テストを実行して緑を確認する。

### 3. W3-1: 検証なしテストの静的判定（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/run.sh`。

1. コメント内の`assert_`だけを含むfixture、リテラル同士の`assert_eq a a`だけを含むfixture、展開を含む健全なfixtureを追加する。
2. 現行実装が前2者を緑にしてしまうことを確認する。
3. `_tests_without_assertion`のAWK判定へ、行コメント除去と実質的なアサーション判定を追加する。引用符・heredocを誤ってコメント扱いしない。
4. 固定値だけの正当なテスト用に`runner-allow`を認め、fixtureの例外が明示的になることを確認する。
5. 既存の自己テストfixtureで健全なものを変数展開付きに更新し、誤検知なく緑になることを確認する。

### 4. W3-2: 補助関数経由のsmothered assertion（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/run.sh`。

1. アサーションを含む補助関数を`$()`、明示的サブシェル、パイプ左辺から呼ぶ3種類のfixtureを追加する。
2. 現行のリテラル検索がこれらを緑にすることを確認する。
3. 同一ファイルの非`test_`関数を抽出し、本文に`assert_`または`_fail`を持つ補助関数名を得る処理を追加する。
4. 危険な呼び出し位置で補助関数名が使われた行を報告し、同一行・直前行の`runner-allow`を尊重する。
5. 直接アサーションの既存検査と統合し、健全な補助関数定義・許可付き終了コード捕捉が誤検知されないことを確認する。

### 5. W3-5: パス検査のheredoc/.github対応（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/run.sh`。

1. `.github/workflows/`配下に新パスリテラルを置くfixtureと、heredoc本文の`#`行に新パスリテラルを置くfixtureを追加する。
2. 現行の対象列挙・行頭コメント除外がこれらを見逃すことを確認する。
3. `.github`をパス検査対象へ加え、対象ゼロ判定・`paths.sh`完全一致除外を壊さない。
4. heredocの開始・終端を追跡し、本文中の`#`を行頭コメントとして除外しない。
5. 動的な文字列連結を意図して解析しない限界を実装コメントに明記する。

### 6. W3-6: 台帳の双方向検査（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/run.sh`。

1. 台帳に載せない追加の`test-extra.sh`を生成し、現行実装が全件を実行しても緑にすることを確認する。
2. 実在する`test/test-*.sh`と台帳のファイル別キーを全件実行時に比較する処理を追加する。
3. 台帳側の欠落ファイル検査を維持し、`CTS_MIN_TESTS=0`で件数・一覧検査を明示的に無効化できることを自己テストする。
4. パターン実行時には既存どおり選択ファイルだけの件数検査となることを確認する。

### 7. W3-3: skipの集計・上限・禁止モード（RED → GREEN）

対象: `test/test-runner-selftest.sh`、`test/run.sh`、必要な場合のみ`test/expected-min-count`。

1. `skip:`マーカーを出して0で終了するfixtureを追加し、現行実装が成功件数へ数えることを確認する。
2. テストごとにskipマーカーを検出し、成功件数へ加えずskip件数を集計する処理を追加する。
3. 成功・失敗・スキップを含む最終集計を追加し、既存の失敗一覧・終了コードを維持する。
4. 台帳の`skip-max N`を読み取り、上限超過で失敗する自己テストを追加する。
5. `CTS_NO_SKIP=1`を設定した実行でskipを失敗扱いにする自己テストを追加する。
6. 現在の通常環境で観測したskip件数を実台帳へ設定し、root環境の成功結果が理由付きで再現できることを確認する。

### 8. リファクタリングと回帰確認

各RED/GREENサイクル後、共通の台帳解析・マーカー検出・エラーメッセージ生成に重複があれば、挙動を変えない範囲で整理する。次を確認する。

- W3-1〜6の各自己テストが、ゲートの改変を緑のまま通さない。
- 既存のテストfixtureがW3-1の新しい判定で不必要に失敗しない。
- W3-7対象ファイル、実装スクリプト、CI設定に差分がない。
- 台帳の総件数・ファイル別下限が実測値を下回らない。

## 検証コマンド

```bash
bash test/run.sh
bash test/run.sh runner-selftest
bash -n test/run.sh test/lib/assert.sh test/test-runner-selftest.sh
git diff --check
git status --short
```

失敗時は、まず失敗した自己テストを単独で再現し、原因を修正してから全テストへ戻る。テストを弱めて緑にする変更は行わない。

## 完了条件

- 設計書と実装計画がコミット済みである。
- W3-1〜6の実装と自己テストが完了している。
- 全テスト、構文検査、空白検査が成功している。
- 独立したサブエージェントによる敵対的レビューと、指摘修正後の再レビューが完了している。
- Issue #7を参照する日本語コミットとPRを作成し、ユーザーへマージを依頼している。
- エージェント自身はマージしない。
