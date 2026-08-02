# SessionStart matcher 追加実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SessionStart`へ登録するhandoffフックを`startup`/`clear`に限定するmatcher付き設定へ移行し、既存設定・台帳・アンインストールの互換性を保つ。

**Architecture:** `install.sh`は`--matcher SessionStart=startup|clear`をフック登録ユーティリティへ渡す。`lib/settings-hooks.py`はmatcherを登録グループへ付けるが、台帳の識別子は従来どおりクォート済みコマンド文字列を使い、旧matcher無し登録を再インストールで置き換える。`handoff-check.sh`内部のsource判定は防御層として変更しない。

**Tech Stack:** Bash、Python 3標準ライブラリ、依存ゼロのbashテストランナー、Claude Code hooks JSON。

## Global Constraints

- Issue #18の番号付きブランチ`issue-18-sessionstart-matcher`だけで作業し、`main`へ直接変更しない。
- `SessionStart`の自前フックは`startup|clear`だけを対象にし、`resume`/`compact`/未知のsourceでは消費しない。
- 既存の利用者フック、matcher付きグループ、設定キー、台帳の旧形式を壊さない。
- matcher設定だけに安全性を依存せず、`handoff-check.sh`のfail-closed判定を残す。
- 実装コードを書く前に、追加テストが期待どおり失敗することを確認する。
- コミット、レビューコメント、Issue/PR本文は日本語で記述し、マージはユーザーへ依頼する。

---

### Task 1: matcher契約の失敗テストを先に追加する

**Files:**
- Modify: `test/test-install.sh:20-46,53-74,573-591`

**Interfaces:**
- Produces: `_hook_matchers EVENT`が`settings.local.json`の各matcherを1行ずつ返すテストヘルパー。
- Produces: 新規登録・再登録・旧形式移行・不正引数の期待動作を固定するテスト。

- [ ] **Step 1: matcher読み出しヘルパーを追加する**

`_hook_commands`の隣に、設定グループの`matcher`を読み出す次のヘルパーを追加する。

```bash
_hook_matchers() {
  local event="$1"
  if [ ! -f "$SETTINGS" ]; then
    HOOK_MATCHERS='(settings.local.json は存在しない)'
    return 0
  fi
  HOOK_MATCHERS="$(python3 -c '
import json, sys
event = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
for group in data.get("hooks", {}).get(event, []):
    print(group.get("matcher", ""))
' "$event" "$SETTINGS" 2>"$TEST_TMP/.matchererr")" ||
    _fail "settings.local.json のmatcherを解析できない: $(cat "$TEST_TMP/.matchererr")"
  printf '%s\n' "$HOOK_MATCHERS"
}
```

- [ ] **Step 2: 新規登録と冪等性の期待値を追加する**

`test_settings_が無ければ作って_SessionStart_に登録する`へ次を追加し、
`test_二度実行してもフックが重複しない`にも同じmatcherの一致を追加する。

```bash
assert_eq "startup|clear" "$(_hook_matchers SessionStart)" "SessionStart のmatcher"
```

- [ ] **Step 3: 旧matcher無し登録の移行テストを追加する**

`test/test-install.sh`へ次のテストを追加する。現在の実装では`--matcher`を解釈できず終了するか、matcher無しで再登録するため失敗する。

```bash
test_旧形式のSessionStart登録をmatcher付きへ移行する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver"
  python3 - "$SETTINGS" "$TARGET/.token-saver/installed.json" \
    "$REPO_ROOT/scripts/handoff-check.sh" <<'PY'
import json
import shlex
import sys

settings, ledger, command = sys.argv[1:]
quoted = shlex.quote(command)
with open(settings, "w") as f:
    json.dump({"hooks": {"SessionStart": [{"hooks": [
        {"type": "command", "command": quoted}
    ]}]}}, f)
with open(ledger, "w") as f:
    json.dump({"hooks": [quoted]}, f)
PY

  local out rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$TARGET/.token-saver/installed.json" \
    --matcher "SessionStart=startup|clear" \
    "SessionStart:$REPO_ROOT/scripts/handoff-check.sh" 2>&1)" || rc=$?
  assert_eq "0" "$rc" "旧形式移行の終了コード: $out"
  assert_eq "startup|clear" "$(_hook_matchers SessionStart)" "移行後のmatcher"
  assert_count 1 "$(_hook_commands SessionStart)" "handoff-check.sh" "移行後の登録数"
}
```

- [ ] **Step 4: 不正matcherの専用エラーを固定する**

既存の設定と台帳を変更せず、`--matcher SessionStart`を終了コード64と専用メッセージで拒否するテストを追加する。

```bash
test_不正なmatcher指定を設定変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.claude" "$TARGET/.token-saver"
  printf '{"permissions":{}}\n' >"$SETTINGS"
  printf '{"skills":[]}\n' >"$TARGET/.token-saver/installed.json"
  cp "$SETTINGS" "$TEST_TMP/settings.before"
  cp "$TARGET/.token-saver/installed.json" "$TEST_TMP/ledger.before"

  local out rc=0
  out="$(python3 "$REPO_ROOT/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$TARGET/.token-saver/installed.json" \
    --matcher SessionStart 2>&1)" || rc=$?
  assert_eq "64" "$rc" "不正matcherの終了コード"
  assert_contains "$out" "matcher の指定が妥当でない" "不正matcherのエラー"
  assert_eq "$(cat "$TEST_TMP/settings.before")" "$(cat "$SETTINGS")" "設定の未変更"
  assert_eq "$(cat "$TEST_TMP/ledger.before")" "$(cat "$TARGET/.token-saver/installed.json")" "台帳の未変更"
}
```

- [ ] **Step 5: focusedテストを実行してREDを確認する**

Run: `bash test/run.sh install`

Expected: 新規登録・移行テストがmatcher未生成または`--matcher`未対応で失敗し、変更前の既存テストは引き続き成功する。

---

### Task 2: settings-hooks.pyへmatcherオプションを実装する

**Files:**
- Modify: `lib/settings-hooks.py:1-6,224-276,326-368`

**Interfaces:**
- Consumes: `--matcher EVENT=REGEX`の辞書と既存の`EVENT:COMMAND`仕様。
- Produces: matcherを持つhook group、終了コード64の入力エラー、既存台帳との互換動作。

- [ ] **Step 1: install仕様を先に正規化する**

`cmd_install`の冒頭で全`EVENT:COMMAND`を検証し、matcherのeventが同じ呼び出しの仕様に存在することを、設定ロード・purge・台帳保存より前に検証する。

```python
def cmd_install(path, ledger_path, specs, matchers):
    parsed_specs = []
    events = set()
    for spec in specs:
        event, separator, command = spec.partition(":")
        if not separator or not event or not command:
            sys.stderr.write("フック指定が妥当でない: %r\n" % spec)
            return 64
        parsed_specs.append((event, command))
        events.add(event)
    for event in matchers:
        if event not in events:
            sys.stderr.write("matcher のイベントがフック指定に無い: %s\n" % event)
            return 64

    data, original = load(path)
```

既存の`for spec in specs`は`for event, command in parsed_specs`へ置き換える。

- [ ] **Step 2: matcher付きhook groupを生成する**

既存のコマンドクォートと台帳記録を維持し、登録グループだけへmatcherを追加する。

```python
        quoted = shlex.quote(command)
        group = {"hooks": [{"type": "command", "command": quoted}]}
        if event in matchers:
            group["matcher"] = matchers[event]
        hooks.setdefault(event, []).append(group)
```

- [ ] **Step 3: CLIでmatcherを解析する**

`main`へ`matchers = {}`を追加し、`--matcher`をinstall時だけ受け付ける。値は最初の`=`で分割し、空値・同一eventの重複・引数不足を終了コード64で拒否する。

```python
        if token == "--matcher":
            if argv[1] != "install" or i + 1 >= len(rest):
                sys.stderr.write("--matcher は install で EVENT=REGEX を1回以上指定する\n")
                return 64
            event, separator, matcher = rest[i + 1].partition("=")
            if not separator or not event or not matcher or event in matchers:
                sys.stderr.write("matcher の指定が妥当でない: %r\n" % rest[i + 1])
                return 64
            matchers[event] = matcher
            i += 2
            continue
```

usage表示を`[--matcher EVENT=REGEX]`付きへ更新し、install呼び出しを`cmd_install(argv[2], ledger_path, specs, matchers)`へ変更する。removeではmatcherを受け付けない。

- [ ] **Step 4: settings-hooksのfocusedテストをGREENにする**

Run: `bash test/run.sh install`

Expected: Task 1で追加した新規登録・旧形式移行・不正matcherテストを含め、installスイートが成功する。`handoff-check.sh`の実装はまだ変更しない。

---

### Task 3: install.shからSessionStart matcherを渡す

**Files:**
- Modify: `install.sh:286-330`
- Test: `test/test-uninstall.sh:803-823`（既存契約をmatcher付き登録で再実行）

**Interfaces:**
- Consumes: `settings-hooks.py --matcher EVENT=REGEX`。
- Produces: 通常インストール時の`SessionStart` matcher付き設定。

- [ ] **Step 1: matcher引数配列を追加する**

フック仕様配列の近くへ`hook_matchers=()`を追加し、`handoff-check.sh`が存在するときだけ次を追加する。

```bash
hook_matchers=()
if [ -f "$CTS_HOME/scripts/handoff-check.sh" ]; then
  hook_specs+=("SessionStart:$CTS_HOME/scripts/handoff-check.sh")
  hook_matchers+=("--matcher" "SessionStart=startup|clear")
else
  warn "scripts/handoff-check.sh が無いため SessionStart フックを登録しない（クローンが不完全である）"
fi
```

- [ ] **Step 2: settings-hooks.py呼び出しへ配列を渡す**

既存の`--ledger`と`hook_specs`の間へ`${hook_matchers[@]}`を渡す。

```bash
  python3 "$CTS_HOME/lib/settings-hooks.py" install "$SETTINGS" \
    --ledger "$LEDGER" "${hook_matchers[@]}" "${hook_specs[@]}"
```

matcherはhandoffフックが実在するときだけ渡し、Stopフックだけが登録される不完全クローンでは無関係なmatcherを渡さない。

- [ ] **Step 3: install/uninstall/handoffの回帰テストを実行する**

Run: `bash test/run.sh install`

Expected: installスイートが全件成功し、新規設定のmatcherが`startup|clear`になる。

Run: `bash test/run.sh uninstall`

Expected: matcher付き自前グループから自分のエントリだけが外れ、同居する利用者フックが残る。

Run: `bash test/run.sh handoff`

Expected: `startup`/`clear`だけ発火し、`resume`/`compact`/未知のsourceは無出力のまま成功する。

---

### Task 4: 利用者向け文書と仕様書を実装へ同期する

**Files:**
- Modify: `README.md:34-40,240-248`
- Modify: `skills/session-handoff/SKILL.md:113-119`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md:140-145,340-345`

**Interfaces:**
- Consumes: 実装済みの設定matcherと`handoff-check.sh`のsource契約。
- Produces: インストール方法、発火条件、設計仕様の一致した説明。

- [ ] **Step 1: READMEのインストール説明を更新する**

SessionStart登録が`matcher: "startup|clear"`付きであることを明記し、発火条件の説明から誤った`resume`を削除する。`compact`、`fork`、fail-closed、`CTS_FORCE=1`の説明は残す。

- [ ] **Step 2: session-handoff SKILLの設定経路を補足する**

既存の`startup`/`clear`契約の直前に、設定側matcherでも同じ発火源へ絞っていることと、スクリプト内部のfail-closed判定も残ることを追記する。

- [ ] **Step 3: 元仕様書の登録・発火条件を更新する**

`handoff-check.sh`の発火源を`startup`/`clear`へ修正し、インストール手順へ`SessionStart`のmatcher指定を追記する。`resume`/`compact`を消費しない不変条件は維持する。

- [ ] **Step 4: 文書と静的検査を確認する**

Run: `git diff --check`

Expected: 空白エラーなし。

Run: `rg -n "startup.*clear|resume|compact|matcher" README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md`

Expected: 利用者向けの発火条件が`startup`/`clear`で一貫し、`resume`は「発火しない」文脈だけに残る。

---

### Task 5: 全検証と変更のコミット

**Files:**
- Verify: `AGENTS.md`, `CLAUDE.md`, `install.sh`, `lib/settings-hooks.py`, `scripts/handoff-check.sh`, `test/test-install.sh`, `test/test-uninstall.sh`, `test/test-handoff-check.sh`

- [ ] **Step 1: 構文・契約検査を実行する**

Run: `bash -n install.sh scripts/handoff-check.sh test/test-install.sh test/test-uninstall.sh`

Expected: 終了コード0。

Run: `python3 -B -c 'import ast; ast.parse(open("lib/settings-hooks.py", encoding="utf-8").read())'`

Expected: 終了コード0、リポジトリへ`__pycache__`を作らない。

Run: `cmp -s AGENTS.md CLAUDE.md`

Expected: 終了コード0。

- [ ] **Step 2: 全テストを実行する**

Run: `bash test/run.sh`

Expected: 失敗0件、スキップ0件。ベースライン383件に追加テストを加えた総件数を記録する。

- [ ] **Step 3: bash 3.2向けE2Eを実行する**

Run: `bash test/bash32-e2e.sh`

Expected: 終了コード0。環境にbash 3.2が無い場合は、実行結果を記録し、既存CIのbash32ジョブ結果と分けて報告する。

- [ ] **Step 4: 差分を確認してコミットする**

Run: `git diff --stat && git diff --check && git status --short`

Expected: Issue #18に関係する設計書、計画書、実装、テスト、文書だけが差分に含まれる。

```bash
git add install.sh lib/settings-hooks.py test/test-install.sh README.md \
  skills/session-handoff/SKILL.md \
  docs/specs/2026-07-31-claude-token-saver-design.md \
  docs/superpowers/plans/2026-08-02-sessionstart-matcher.md
git commit -m "Issue #18: SessionStart matcherを追加"
```

---

### Task 6: 独立レビュー、修正ループ、PR作成

**Files:**
- Review: Task 5のコミット差分全体
- Update: 必要な実装・テスト・文書

- [ ] **Step 1: 独立サブエージェントへ敵対的レビューを依頼する**

実装者とは別のサブエージェントへ、base SHAとhead SHA、受入条件、次の観点を渡して読み取り専用レビューを依頼する。

- 設定matcherとスクリプト内部判定のsource集合が一致しているか
- `--matcher`の不正入力が設定・台帳を書き換えないか
- 既存matcher付き利用者フックや同居グループを巻き込まないか
- Windows風パス・コロンを含むコマンド仕様を壊していないか
- 旧台帳からの再インストールとアンインストールが成立するか
- ドキュメントが`resume`を誤って発火対象として案内していないか

- [ ] **Step 2: Critical/Important指摘をTDDで修正する**

指摘があれば、先に再現テストを追加して失敗を確認し、最小修正、focusedテスト、全テスト、再レビューの順で繰り返す。Minor指摘も、Issue #18の受入条件に関係するものは同じループで解消する。

- [ ] **Step 3: ブランチをpushしてPRを作成する**

検証済みのIssue #18ブランチを`origin`へpushし、baseを`main`、Issue #18をリンクした日本語PRを作成する。PR本文には変更理由、matcherの設定値、fail-closed維持、テスト結果、レビュー結果を記載する。

- [ ] **Step 4: マージをユーザーへ依頼する**

エージェントはマージしない。PR URLと検証結果を報告し、ユーザーのマージ完了通知を待つ。マージ後は`main`同期、ローカル・リモートのIssue #18ブランチ削除、clean確認を行う。
