# Issue #31: clock rollback時のtoken-report freshness誤失敗修正 設計

- 作成日: 2026-08-05
- 対象Issue: #31
- 基点: `origin/main` (`e1391bd6257fe63e62a01bee2ab6d4f46ec7e18d`)
- 状態: 実装前・設計承認済み

## 1. 目的

`scripts/token-report.sh --out <path>` が、実行中のwall-clock逆行や粗いmtime解像度に影響されず、今回の実行が生成したレポートだけを成功として扱えるようにする。既存のstale report保護、公開CLI、レポート形式、calibration契約は維持する。

## 2. 根本原因

現在の明示 `--out` は、launcher開始時に作ったmarkerと利用者指定レポートを `-nt` で比較する。計測器が正常に書き込んでも時計が逆行すると、新しいレポートのmtimeがmarkerより古くなり、次の偽失敗になる。

```text
レポートがこの実行で更新されていません: <path>
```

mtimeは生成主体を証明しない。未来mtimeのstale file、同一秒、clock rollbackのいずれも単純な時刻比較では同時に正しく扱えない。

## 3. 採用する方式

明示 `--out` でも計測器へ利用者指定パスを直接渡さない。出力先と同じ親ディレクトリに実行専用の一時ファイルを作り、計測器の `--out` だけをそのパスへ差し替える。

処理順序は次のとおりとする。

1. CLI引数を従来どおり検証し、利用者指定 `out_path` を保持する。
2. 親ディレクトリが存在することを要求し、勝手に作成しない。
3. `out_path` がsymlinkなら参照先を追わず失敗する。
4. 同じ親ディレクトリへ権限 `umask` に従う一意な一時ファイルを `mktemp` で作る。
5. 計測器へ渡す `--out` を一時ファイルへ置き換え、他の引数の順序と値を保持する。
6. 計測器の終了コードをそのまま尊重する。
7. 一時ファイルが通常の非空ファイルであり、先頭40行に `## 計測条件` を含むことを検証する。
8. `--calibrate` の場合は既存どおり、今回生成された通常の非空snapshotであることを検証する。
9. すべて成功した場合だけ一時ファイルを `out_path` へ `mv` し、最終パスを出力する。
10. 途中失敗では一時ファイルだけを削除し、実行前からある `out_path` は変更しない。

一時ファイルを同じ親ディレクトリへ置くことで、最終renameを同一filesystem内のatomic置換にする。freshnessは「このプロセスだけが知る一時パスへ計測器が有効な成果物を書いたこと」で証明し、mtimeを判定材料から完全に外す。

## 4. 既定出力との関係

引数なしの既定出力は、既にlauncher専用の `/tmp/cts-token-report-output.*` へ計測器を書かせ、検証後に `.token-saver/token-reports/` へ原子的に配置している。この契約は変更しない。

明示出力だけを同じ「専用一時ファイル→検証→配置」の形へ揃える。既定出力の連番、同時起動、date失敗、配置失敗の契約は変更しない。

## 5. エラーと復旧

- 親ディレクトリ不在: 非ゼロで終了し、ディレクトリを作成しない。
- symlink出力先: 非ゼロで終了し、リンクと参照先を変更しない。
- 一時ファイル作成失敗: 非ゼロで終了し、既存出力を変更しない。
- 計測器非ゼロ: その終了コードを返し、一時ファイルを削除する。
- 計測器成功だが未生成・空・形式不正: 非ゼロで終了し、既存出力を変更しない。
- calibration snapshot不正: 非ゼロで終了し、既存出力を変更しない。
- 最終 `mv` 失敗: 非ゼロで終了し、既存出力を変更せず、一時ファイルをcleanupする。
- 成功: 既存出力を原子的に置換し、`書き出しました: <利用者指定パス>` を出す。

launcherが作成した一時パスはtrapで必ずcleanupする。利用者が実行前から持つ出力はcleanup対象にしない。

## 6. 公開互換性

次を維持する。

- `token-report.sh` の `--days`、`--out`、`--top`、`--all-projects`、`--paths`、`--calibrate`。
- `--out VALUE` と `--out=VALUE` の両形式。
- 親ディレクトリを自動作成しない契約。
- 計測器の非ゼロ終了コード伝播。
- 非空、`## 計測条件`、calibration snapshotの検証。
- 成功時の最終出力パス表示。

mtime、inode、内部一時パスは公開契約に含めない。

## 7. テスト設計

`test/test-token-report-launcher.sh` の実計測器fixtureへ、生成後にレポートmtimeを過去へ戻すモードを追加する。既存実装ではmarkerより新しくないため失敗し、新実装では実行専用一時ファイルの内容を根拠に成功することをRED→GREENで確認する。

追加・更新する回帰テストは次のとおりである。

1. clock rollback相当として生成物mtimeを過去へ戻しても、今回生成したレポートを指定パスへ配置する。
2. 実行前からある未来mtimeのstale reportを、touchless計測器で成功扱いせず内容も保持する。
3. 計測器が空出力、形式不正、非ゼロの場合に既存レポートを保持する。
4. `--out` と `--out=` の両方で計測器へprivate tempを渡し、最終パスへだけ配置する。
5. 親不在、symlink出力、最終move失敗で利用者ファイルを変更しない。
6. `--calibrate` のsnapshot検査に失敗した場合も既存レポートを保持する。
7. 既定出力の連番・同時起動・atomic配置を維持する。

focused launcher test、token-report本体、calibration、Python 3.6/3.8互換性、Bash 3.2、全テストを実行する。最後に `git diff --check` と実diffを確認する。

## 8. 変更範囲

変更対象は `scripts/token-report.sh`、`test/test-token-report-launcher.sh`、必要な説明を持つ設計・計画文書に限定する。Issue #30のSessionStart、install、uninstall、Codex hook変更は含めない。
