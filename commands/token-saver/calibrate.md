---
description: 確認済みキャリブレーション snapshot を設定へ明示適用する
disable-model-invocation: true
---

ロジックを再実装しない。閾値を変えるのは明示適用だけである。

先に snapshot が無い、または未確認なら適用せず、必要なら先に次で作るよう案内せよ。

```bash
./.token-saver/token-report.sh --calibrate
```

確認済み snapshot を適用するときだけ、次を実行する。

```bash
./.token-saver/token-calibrate.sh --apply
```

`--apply` 以外の使い方を発明しない。
