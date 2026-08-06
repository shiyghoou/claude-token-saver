---
description: 導入先のトークン消費レポートを出す（token-report entrypoint を実行）
disable-model-invocation: true
---

ロジックを再実装しない。導入先の entrypoint をそのまま実行せよ。

```bash
./.token-saver/token-report.sh
```

日数や `--all-projects` などが必要なら、利用者の指示を同じ entrypoint の引数として渡せ。
レポートの読み方を詳しく書く必要があれば既存の `token-report` スキルを参照してよいが、要約そのものはこのコマンドで足りる。
