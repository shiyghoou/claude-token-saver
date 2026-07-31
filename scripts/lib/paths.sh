#!/usr/bin/env bash
# token-saver が管理するパスの単一情報源。
#
# install.sh / uninstall.sh / scripts/lib/common.sh がこれを source する。
# パスを2箇所以上に書くと、片方だけ直したときに両方とも検証できなくなる
# （実測: 同じ検証を2層に書いた結果、どちらの層も改変を検出できなくなった）。
#
# ここで返すのは導入先リポジトリのルートからの相対パスだけである。絶対パスの
# 組み立ては呼び出し側が行う。install.sh は $TARGET を、フックは
# cts_project_dir を基準にするため、基準が1つに定まらない。
#
# 引き継ぎと台帳を .claude/ 配下ではなくルート直下へ置くのは、Claude Code 以外
# のエージェント（Codex CLI など）からも同じ場所を参照できるようにするためである。
# フック登録（.claude/settings.local.json）とスキル本体（.claude/skills/）は
# Claude Code がパスを決めるため動かせない。

cts_base_rel()           { printf '%s' '.token-saver'; }
cts_handoff_rel()        { printf '%s' '.token-saver/handoff'; }
cts_ledger_rel()         { printf '%s' '.token-saver/installed.json'; }

# 旧パス。install.sh の移行と uninstall.sh のフォールバックだけが使う。
cts_legacy_handoff_rel() { printf '%s' '.claude/.handoff'; }
cts_legacy_state_rel()   { printf '%s' '.claude/.token-saver'; }
cts_legacy_ledger_rel()  { printf '%s' '.claude/.token-saver/installed.json'; }
