---
description: セッション切り時提案スクリプトを手動で走らせる（Stop フックと同条件）
disable-model-invocation: true
---

ロジックを再実装しない。install が Stop フックへ登録した `suggest-session-cut.sh` を使う。

優先順位:

1. `.claude/settings.local.json` の Stop フック command から `suggest-session-cut.sh` のパスを取り、それを実行する
2. このコマンド定義がシンボリックリンクなら、定義の親クローン直下の `scripts/suggest-session-cut.sh` を実行する

stdin には Stop フック相当の JSON（少なくとも `cwd` / `session_id` / `transcript_path`）を渡せ。現セッションの値が取れなければ実行せず、その旨を伝えよ。`/clear` は自動実行しない。
