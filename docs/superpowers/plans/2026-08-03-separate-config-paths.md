# Issue #16: 個人設定と共有設定の分離実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `install.sh` と `uninstall.sh` に個人設定専用・共有設定専用の実行スコープを追加し、既定動作の後方互換性と未追跡ファイル保護を維持する。

**Architecture:** CLI引数を各シェルスクリプトの入口で `all` / `personal` / `shared` に正規化する。`install.sh` は個人側の既存処理（状態・entrypoint・settings・フック・スキル・台帳）と共有側の`.gitignore`処理を条件付きで分け、sharedモードでは既存台帳を読み取り専用で使って実際に記録されたスキルだけを列挙する。`uninstall.sh` は同じスコープを使い、sharedモードでは個人用設置物を削除せず、残存する管理対象がある場合に`.gitignore`を残す。

**Tech Stack:** Bash、Python 3標準ライブラリ（`lib/ledger.py`、`lib/gitignore-block.py`、`lib/settings-hooks.py`）、既存のBashテストランナー、Docker上のBash 3.2 E2E。

## Global Constraints

- 引数なしは個人設定と共有設定を扱う既存の全体動作とし、既存利用者の再実行を壊さない。
- `--personal` と `--shared` は相互排他的であり、未指定時のスコープは`all`である。
- `install.sh --shared` は`.gitignore`だけを変更し、settings・フック・スキル・状態・台帳を変更しない。
- `install.sh --personal` は`.gitignore`を読み書きせず、個人側だけを変更する。
- `uninstall.sh --personal` は`.gitignore`を変更せず、`uninstall.sh --shared` は個人用設置物を変更しない。
- sharedモードは台帳が無いスキルを推測して`.gitignore`へ追加せず、uninstallは`--guess`なしで利用者の設置物を削除しない。
- `.gitignore`、settings、台帳の原子的書き込み・シンボリックリンク拒否・権限保持・改行保持を既存実装から引き継ぐ。
- フックのmatcher、パス、台帳の行プロトコル、token-report集計ロジックは変更しない。
- 作業は`issue-16-separate-config-paths`ブランチで行い、mainへ直接編集・直接マージしない。
- すべてのテスト名、コミットメッセージ、Issue/PRコメントは日本語で記述する。

---

## File Map

- Modify: `install.sh` — スコープ引数の解析、個人処理と共有処理の条件分岐、台帳からの安全なスキル列挙。
- Modify: `uninstall.sh` — スコープ引数の解析、個人処理・共有処理の分離、sharedモードの残存データ判定。
- Modify: `test/test-install.sh` — installのCLIスコープ、対象外ファイル不変、台帳由来の共有ブロックのfixture。
- Modify: `test/test-uninstall.sh` — uninstallのCLIスコープ、残存設置物と`.gitignore`の保護、モード間往復のfixture。
- Modify: `README.md` — CLIヘルプとpersonal/sharedの利用方法、未追跡ファイルと共有設定の注意事項。
- Modify: `skills/session-handoff/SKILL.md` — 導入・取り外し時のスコープ選択と既定動作を同期。
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md` — 既存設計のインストール節にIssue #16のスコープ契約を追記。
- Create: `docs/superpowers/specs/2026-08-03-separate-config-paths-design.md` — 承認済み設計（コミット済み）。
- Create: `docs/superpowers/plans/2026-08-03-separate-config-paths.md` — 本計画。

## Task 1: CLIスコープ解析の失敗テストを追加する

**Files:**
- Modify: `test/test-install.sh:13-18` — 引数付きinstall実行ヘルパーを追加。
- Modify: `test/test-uninstall.sh:15-30` — 引数付きuninstall実行ヘルパーを追加。

**Interfaces:**
- `install.sh --personal <target>`、`install.sh --shared <target>`を受け付ける。
- `uninstall.sh --personal <target>`、`uninstall.sh --shared <target>`を受け付ける。
- `uninstall.sh --guess <target>`は従来どおり受け付け、`--shared --guess <target>`は拒否する。
- 重複スコープ、未知のオプション、複数の導入先は既存ファイルを変更する前に非0で終了する。

- [ ] **Step 1: 引数付き実行ヘルパーを追加する**

  `test/test-install.sh`へ次の形のヘルパーを追加し、既存の`_run_install`は変更しない。

  ```bash
  _run_install_args() {
    bash "$INSTALL" "$@" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
    INSTALL_STATUS=$?
    INSTALL_OUT="$(cat "$TEST_TMP/.out")"
    INSTALL_ERR="$(cat "$TEST_TMP/.err")"
  }
  ```

  `test/test-uninstall.sh`にも同じ契約で`_run_uninstall_args`を追加する。

- [ ] **Step 2: 不正なスコープ指定が変更前に拒否されるテストを書く**

  `test/test-install.sh`に次のテストを追加する。

  ```bash
  test_インストールの重複スコープを変更前に拒否する() {
    _setup_target
    printf '利用者の設定\n' >"$TARGET/.gitignore"
    cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
    _run_install_args --personal --shared
    assert_ne "0" "$INSTALL_STATUS" "終了コード"
    cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" ||
      _fail "不正なスコープ指定で.gitignoreが変更された"
    assert_contains "$INSTALL_OUT$INSTALL_ERR" "スコープ" "エラー"
  }
  ```

  `test/test-uninstall.sh`には`--shared --guess`の拒否と複数ディレクトリの拒否を同じ形式で追加する。

- [ ] **Step 3: 追加テストだけを実行してREDを確認する**

  Run: `bash test/run.sh install`

  Expected: 新しいスコープ受け入れテストが失敗し、既存テストは成功する。失敗理由は現行スクリプトが`--personal` / `--shared`を未知のオプションとして扱うことである。

- [ ] **Step 4: テスト追加をコミットする**

  ```bash
  git add test/test-install.sh test/test-uninstall.sh
  git commit -m "Issue #16: 設定スコープの失敗テストを追加"
  ```

## Task 2: install.shにpersonal/sharedスコープを実装する

**Files:**
- Modify: `install.sh:15-45` — `scope`、`do_personal`、`do_shared`を決める引数解析。
- Modify: `install.sh:79-105` — 個人側だけで行う管理対象symlink検査とsettings writable check。
- Modify: `install.sh:109-268` — sharedモードで状態・移行・entrypointを作らない条件分岐。
- Modify: `install.sh:284-430` — フック・スキル・台帳を個人側へ限定し、共有モードの台帳読み取りを追加。
- Modify: `install.sh:432-463` — sharedスコープだけで`.gitignore`を再生成し、personalでは完全にスキップ。
- Test: `test/test-install.sh` — スコープごとの対象ファイル不変と台帳由来のスキル検証。

**Interfaces:**
- 引数解析後の`scope`は`all`、`personal`、`shared`のいずれかである。
- `do_personal=1`のときだけ、移行・状態・entrypoint・settings・フック・スキル・台帳を処理する。
- `do_shared=1`のときだけ、`.gitignore`の存在確認・writable check・`gitignore-block.py apply`・共有更新を処理する。
- sharedモードの一時配列`installed_skills`は、現在台帳、旧台帳の順に`ledger.py list-skills`から読み、`name`が空・`.`・`..`・`/`を含む記録を警告して除外する。

- [ ] **Step 1: personal/sharedの対象ファイル不変テストを書く**

  `test/test-install.sh`に次のfixtureを追加する。

  ```bash
  test_install_personal_は_gitignore_を変更しない() {
    _setup_target
    printf '利用者の除外\n' >"$TARGET/.gitignore"
    cp "$TARGET/.gitignore" "$TEST_TMP/gitignore.before"
    _require_mtime "$TARGET/.gitignore"
    before="$(_mtime "$TARGET/.gitignore")"
    _run_install_args --personal
    after="$(_mtime "$TARGET/.gitignore")"
    assert_eq "0" "$INSTALL_STATUS" "終了コード"
    cmp -s "$TEST_TMP/gitignore.before" "$TARGET/.gitignore" || _fail ".gitignoreが変更された"
    assert_eq "$before" "$after" ".gitignoreのmtime"
    assert_file_exists "$SETTINGS" "個人settings"
    assert_file_exists "$TARGET/.token-saver/installed.json" "個人台帳"
  }

  test_install_shared_は_gitignore_だけを更新する() {
    _setup_target
    _run_install_args --shared
    assert_eq "0" "$INSTALL_STATUS" "終了コード"
    assert_file_exists "$TARGET/.gitignore" ".gitignore"
    assert_contains "$(cat "$TARGET/.gitignore")" ".token-saver/" ".gitignore"
    assert_file_missing "$SETTINGS" "settings"
    assert_file_missing "$TARGET/.token-saver" "状態ディレクトリ"
    assert_file_missing "$TARGET/.claude/skills" "スキル"
  }
  ```

- [ ] **Step 2: 台帳あり・台帳なしのsharedテストを書く**

  台帳ありでは`skills`へ`session-handoff`と利用者所有の別名を記録し、`.gitignore`には台帳にある`session-handoff`だけが出ることを確認する。台帳なしでは`.token-saver/`だけが出て、`.claude/skills/session-handoff`を推測して追加しないことを確認する。台帳と`.gitignore`のテストfixtureは導入先のファイル以外を作成しない。

- [ ] **Step 3: install.shのスコープ解析を実装する**

  既存の位置引数解析を拡張し、`scope`を一度だけ設定する。`--personal`と`--shared`の重複はエラー、引数なしは`all`、ヘルプには次を含める。

  ```text
  usage: install.sh [--personal|--shared] [<導入先ディレクトリ>]
    --personal  個人設定・フック・スキル・状態だけを更新する
    --shared    .gitignoreだけを更新する
    （オプションなしは従来どおり両方を更新する）
  ```

  解析終了後に`do_personal`と`do_shared`を設定し、以後の処理はこの2値だけを参照する。これにより、各処理段階で引数文字列を再解釈しない。

- [ ] **Step 4: 個人側の初期検査・移行・entrypointをガードする**

  `do_personal=1`のときだけ`cts_reject_managed_symlinks`、settingsの`check-writable`、状態ディレクトリ作成、旧パス移行、`cts_install_token_report_entrypoint`を実行する。sharedモードでは`python3`と`.gitignore`だけを必要とし、`.claude`配下や台帳へ触れない。

- [ ] **Step 5: 個人側のフック・スキル・台帳更新をガードする**

  フック登録とスキル配置を`if [ "$do_personal" = 1 ]`で囲み、personal/allでは既存の`installed_skills`収集と台帳更新をそのまま使う。personalモードの完了メッセージには、`.gitignore`を変更していないため必要なら`install.sh --shared`を実行する旨を追加する。失敗時の復旧案内もスコープに応じて`uninstall.sh --personal`または`uninstall.sh --shared`を示す。

- [ ] **Step 6: shared用の台帳読み取りと`.gitignore`更新を実装する**

  `.gitignore`処理の直前に、sharedモードでだけ次の順にスキル名を読み込む関数を置く。

  ```bash
  cts_load_recorded_skills() {
    local ledger_path="$1" name src mode
    python3 "$CTS_HOME/lib/ledger.py" has-record "$ledger_path" skills || return 0
    while IFS=$'\037' read -r name src mode; do
      case "$name" in
        "" | . | .. | */*) warn "台帳のスキル名が不正なので.gitignoreへ追加しない: $name"; continue ;;
      esac
      installed_skills+=("$name")
    done < <(python3 "$CTS_HOME/lib/ledger.py" list-skills "$ledger_path")
  }
  ```

  現在台帳に記録が無ければ旧台帳を読み、どちらにも記録が無ければ配列を空のままにする。shared/allでだけ`gitignore_existed`を計算し、`gitignore-block.py apply`を呼ぶ。sharedでは`ledger.py set-flag`を呼ばず、`.gitignore`が新規作成されても台帳を新規作成しない。

- [ ] **Step 7: installのfocusedテストをGREENにする**

  Run: `bash test/run.sh install`

  Expected: installテストが全件成功し、personalでは`.gitignore`不変、sharedでは個人ファイル不在、台帳由来のスキルだけという結果になる。

- [ ] **Step 8: install実装をコミットする**

  ```bash
  git add install.sh test/test-install.sh
  git commit -m "Issue #16: installの個人共有スコープを分離"
  ```

## Task 3: uninstall.shにpersonal/sharedスコープを実装する

**Files:**
- Modify: `uninstall.sh:19-52` — `scope`、`do_personal`、`do_shared`、`--guess`の組み合わせ解析。
- Modify: `uninstall.sh:80-128` — 個人側検査と共有側の読み取り専用台帳選択。
- Modify: `uninstall.sh:136-278` — 個人用entrypoint・フック・スキル処理をpersonal/allへ限定。
- Modify: `uninstall.sh:282-299` — shared/allだけで`.gitignore`を処理。
- Modify: `uninstall.sh:299-420` — personal/sharedごとの台帳・器・残存データ後処理。
- Test: `test/test-uninstall.sh` — 個人・共有の取り外しと残存データ保護。

**Interfaces:**
- `scope=personal`では個人用設置物を既存規則で外し、`.gitignore`編集を一度も呼ばない。
- `scope=shared`では`.gitignore`ブロックだけを外し、台帳・settings・フック・スキル・entrypoint・状態を削除しない。
- sharedモードの残存判定は、台帳に記録されたスキル/entrypointと、handoff/stateの実ファイルを読み取り専用で確認する。残存時は`skills_left`または`shared_leftovers`を立て、ブロックを残す。
- `--shared --guess`は引数エラーであり、ファイル変更を開始しない。

- [ ] **Step 1: uninstallのスコープ挙動を検証する失敗テストを書く**

  次のfixtureを`test/test-uninstall.sh`へ追加する。

  ```bash
  test_uninstall_personal_は_gitignore_を残す() {
    _setup_target
    _run_install
    gitignore_before="$(cat "$TARGET/.gitignore")"
    _run_uninstall_args --personal
    assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
    assert_eq "$gitignore_before" "$(cat "$TARGET/.gitignore")" ".gitignore"
    assert_not_contains "$(_hook_commands SessionStart)" "handoff-check.sh" "個人フック"
  }

  test_uninstall_shared_は個人用設置物と除外を残す() {
    _setup_target
    _run_install
    printf '未消費\n' >"$TARGET/.token-saver/handoff/pending/a.md"
    _run_uninstall_args --shared
    assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
    assert_file_exists "$SETTINGS" "settings"
    assert_file_exists "$TARGET/.claude/skills/session-handoff" "スキル"
    assert_file_exists "$TARGET/.token-saver/handoff/pending/a.md" "handoff"
    assert_contains "$(_gitignore_text)" ".token-saver/" ".gitignoreの除外"
  }
  ```

  さらに、個人用設置物が無いshared先行fixtureでは`.gitignore`ブロックだけが外れ、空の`.gitignore`自体は所有不明のため残ることを確認する。

- [ ] **Step 2: uninstallの引数解析を実装する**

  `GUESS`と位置引数の既存解析を保ちつつ、`scope`を追加する。ヘルプは次の契約にする。

  ```text
  usage: uninstall.sh [--personal|--shared] [--guess] [<導入先ディレクトリ>]
    --personal  個人設定・フック・スキル・状態だけを外す
    --shared    .gitignoreだけを外す
    --guess     台帳の無い旧環境を推測して外す（個人側のみ）
  ```

  `--personal --guess`は許可し、`--shared --guess`、スコープ重複、未知のオプション、複数ディレクトリはrc 64相当の引数エラーにする。エラー経路では`TARGET`のファイルを読んでも書き換えない。

- [ ] **Step 3: personal側処理をガードする**

  `cts_reject_managed_symlinks`、token-report entrypointの削除、settings hooksのremove、スキル削除、個人用器/backupの後片付けを`do_personal=1`の場合だけ行う。personalではledgerの読み書きと削除は既存どおり行うが、`.gitignore`の`gitignore_created`判定と`gitignore-block.py remove`は行わない。

- [ ] **Step 4: shared側の残存判定を実装する**

  sharedモードでは既存/旧台帳を読むが、`rm`、`ledger.py set-*`、settings hooks removeを実行しない。次の読み取り専用判定を実装する。

  1. 台帳のスキル記録から導入先パスを組み立て、リンク・コピーが残っていれば`shared_leftovers=1`にする。
  2. 台帳にtoken-report sourceの記録があり、導入先entrypointが残っていれば`shared_leftovers=1`にする。
  3. `.token-saver/handoff/`、`.token-saver/`直下のファイル、旧パスの同等箇所に実ファイルまたはリンクがあれば`shared_leftovers=1`にする。
  4. 判定中に利用者の既存スキルを削除・推測しない。

  `shared_leftovers=1`なら警告を追加して`.gitignore`処理をスキップする。残存が無い場合だけ`gitignore-block.py remove`を実行する。共有モードは台帳を削除せず、空の`.gitignore`も削除しない。

- [ ] **Step 5: uninstallのfocusedテストをGREENにする**

  Run: `bash test/run.sh uninstall`

  Expected: uninstallテストが全件成功し、既存のall/guess挙動を維持したまま、personal/sharedの対象外ファイルが不変になる。

- [ ] **Step 6: uninstall実装をコミットする**

  ```bash
  git add uninstall.sh test/test-uninstall.sh
  git commit -m "Issue #16: uninstallの個人共有スコープを分離"
  ```

## Task 4: モード間の往復・権限・複数クローン回帰を補強する

**Files:**
- Modify: `test/test-install.sh` — モード順序、mtime、symlink、未追跡の回帰fixture。
- Modify: `test/test-uninstall.sh` — モード順序、残存ファイル、旧台帳の回帰fixture。
- Modify: `install.sh` / `uninstall.sh` — focused testで見つかった安全性の修正。

**Interfaces:**
- `--shared`→`--personal`、`--personal`→`--shared`、各モードの2回目実行は、対象外を変更せず、対象内は冪等である。
- source cloneを別パスへ複製しても、共有ブロックは相対パスで安定し、settings hooksの絶対パス同定規則は変わらない。

- [ ] **Step 1: モード順序と再実行のテストを書く**

  次のシナリオをfixture化する。

  - `--shared`を2回実行して`.gitignore`のSTART/ENDと`.token-saver/`が1組だけである
  - `--personal`後に`--shared`を実行して、個人settingsの内容/mtimeが変わらず、記録済みスキルが共有ブロックへ現れる
  - `--shared`後に`--personal`を実行して、personal実行が`.gitignore`を変更しない
  - `--personal`を2回実行して、個人フック・スキル・台帳が重複しない

- [ ] **Step 2: symlink・権限・未追跡ファイルのテストを書く**

  `.gitignore` symlink、settings symlink、読み取り専用`.gitignore`、既存の利用者ブロック、台帳に無い利用者スキル、handoff実ファイルを用意する。personalは`.gitignore` symlink/readonlyの影響を受けず、sharedは既存の`.gitignore`保護規則に従い、uninstall sharedは残存ファイルを未追跡化しないことを確認する。

- [ ] **Step 3: 複数クローン相当のテストを書く**

  `_clone_repo`でsource cloneを別パスへ複製し、同一targetへpersonalを再実行する。settings hooksは既存の絶対パス更新、`.gitignore`は同じ相対行、利用者所有スキルは保持されることを確認する。

- [ ] **Step 4: focused回帰を実行して修正する**

  Run: `bash test/run.sh install`

  Run: `bash test/run.sh uninstall`

  Expected: 追加fixtureと既存fixtureがすべて成功する。失敗時は先にテストまたは実装の原因を1件に絞り、修正後に同じfocusedテストを再実行する。

- [ ] **Step 5: 回帰補強をコミットする**

  ```bash
  git add install.sh uninstall.sh test/test-install.sh test/test-uninstall.sh
  git commit -m "Issue #16: 設定スコープの往復安全性を検証"
  ```

## Task 5: CLI・README・SKILL・設計仕様を同期する

**Files:**
- Modify: `README.md:24-112,195-203` — 導入・取り外し・個人設定と共有設定の使い分け。
- Modify: `skills/session-handoff/SKILL.md` — install/uninstallのスコープ契約。
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md:329-396` — 既存設計の導入節と非対称性の更新。
- Modify: `install.sh` / `uninstall.sh` — `--help`の文言が実装と一致することを確認。
- Test: `test/test-token-report-docs.sh` または既存ドキュメントテスト — パス・説明の矛盾があれば更新。

**Interfaces:**
- READMEとSKILLは、引数なしがall、`--personal`が個人側のみ、`--shared`が`.gitignore`のみであることを同じ文言で説明する。
- personal install後に未追跡ファイルが見える可能性と、sharedを明示的に再実行する手順を説明する。
- shared uninstallは個人用設置物を消さず、残存データがあれば`.gitignore`を残すことを説明する。

- [ ] **Step 1: READMEの導入・取り外し節を書き換える**

  既存のall動作の箇条書きを残し、その直後に次のコマンド例を追加する。

  ```bash
  # 個人設定・フック・スキル・状態だけ
  /path/to/claude-token-saver/install.sh --personal <導入先>

  # .gitignoreだけ
  /path/to/claude-token-saver/install.sh --shared <導入先>

  # 個人側を外す。.gitignoreは残す
  /path/to/claude-token-saver/uninstall.sh --personal <導入先>

  # .gitignoreだけを外す。個人用設置物が残る場合は安全側で残す
  /path/to/claude-token-saver/uninstall.sh --shared <導入先>
  ```

- [ ] **Step 2: SKILLと設計仕様の契約を同期する**

  `skills/session-handoff/SKILL.md`の導入手順と、`docs/specs/2026-07-31-claude-token-saver-design.md`のインストール節へ同じスコープ境界を追加する。SessionStart matcherとhandoff本文の仕様は変更しない。

- [ ] **Step 3: ドキュメント検査を実行する**

  Run: `bash test/run.sh token-report-docs`

  Expected: ドキュメントの共有契約検査が成功し、Issue #16のCLI説明に不整合がない。

- [ ] **Step 4: ドキュメントをコミットする**

  ```bash
  git add README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md
  git commit -m "Issue #16: 設定スコープの使い分けを文書化"
  ```

## Task 6: 全体検証とPR前の確定

**Files:**
- Verify: `install.sh`, `uninstall.sh`, `test/test-install.sh`, `test/test-uninstall.sh`, README、SKILL、設計仕様、設計書、計画書。
- Modify: Issue #16対象ファイル — 検証で見つかった不整合のみ。

**Interfaces:**
- 全体テストは既存385件を下回らず、追加テストを含めて失敗0・スキップ0である。
- Bash 3.2 E2Eはフックとtoken-report launcherを成功させる。

- [ ] **Step 1: 構文と差分の静的検査を実行する**

  ```bash
  bash -n install.sh uninstall.sh scripts/handoff-check.sh test/test-install.sh test/test-uninstall.sh
  python3 -B -c 'import ast; ast.parse(open("lib/settings-hooks.py", encoding="utf-8").read()); ast.parse(open("lib/ledger.py", encoding="utf-8").read()); ast.parse(open("lib/gitignore-block.py", encoding="utf-8").read())'
  git diff --check
  find . -type d -name __pycache__ -print
  ```

  Expected:構文・AST・差分検査が成功し、リポジトリ内に`__pycache__`が無い。

- [ ] **Step 2: 全体テストを実行する**

  Run: `bash test/run.sh`

  Expected: `成功 <385以上> 件 / 失敗 0 件 / スキップ 0 件`。

- [ ] **Step 3: Bash 3.2 E2Eを実行する**

  Run: `bash test/bash32-e2e.sh`

  Expected: `OK: bash 3.2 でフックと token-report launcher が正しく動作した`。

- [ ] **Step 4: 変更範囲と作業ツリーを確認する**

  ```bash
  git status --short --branch
  git diff main...HEAD --stat
  git diff main...HEAD --check
  git log --oneline --decorate -8
  ```

  Expected: Issue #16に関係するファイルだけが変更され、未追跡のテスト生成物が無い。

- [ ] **Step 5: PR前のコミットを確定する**

  ```bash
  git add install.sh uninstall.sh test/test-install.sh test/test-uninstall.sh README.md skills/session-handoff/SKILL.md docs/specs/2026-07-31-claude-token-saver-design.md docs/superpowers/specs/2026-08-03-separate-config-paths-design.md docs/superpowers/plans/2026-08-03-separate-config-paths.md
  git commit -m "Issue #16: 個人設定と共有設定の更新経路を分離"
  ```

## Task 7: 独立レビュー・修正ループ・PR公開

**Files:**
- Review: `main...HEAD`の全差分、承認済み設計書、計画書、検証結果。
- Modify: レビューでCritical/Importantまたは妥当なMinorが見つかった対象ファイル。

**Interfaces:**
- 実装者とは別の読み取り専用レビュアーが、スコープ境界、fail-closed、台帳読み取り、残存データ保護、後方互換性、ドキュメント同期を確認する。
- Critical/Importantの指摘が0になるまで修正と再レビューを繰り返す。
- PRは`main`向け、Issue #16を明示し、マージはユーザーへ依頼する。

- [ ] **Step 1: 独立レビューを依頼する**

  レビュアーへ次を渡す。

  - 比較範囲: `main...HEAD`
  - 設計: `docs/superpowers/specs/2026-08-03-separate-config-paths-design.md`
  - 計画: `docs/superpowers/plans/2026-08-03-separate-config-paths.md`
  - 確認点: `--personal`が`.gitignore`へ触れない、`--shared`が個人ファイルへ触れない、台帳なしの推測禁止、共有uninstall時の残存データ保護、allの後方互換、全テストとBash 3.2。

- [ ] **Step 2: 指摘を分類して修正する**

  Critical/Importantは必ず修正する。Minorは設計・安全性・保守性に影響するものだけ修正し、対応しない場合は理由をPRコメントへ記録する。修正後はfocusedテスト、全体テスト、必要なE2Eを再実行する。

- [ ] **Step 3: 修正後に同じ観点で再レビューする**

  再レビュー結果が`Ready`、Critical 0、Important 0になるまで繰り返す。レビュー結果と検証コマンドをPR本文またはコメントへ日本語で記録する。

- [ ] **Step 4: pushしてPRを作成する**

  ```bash
  git push -u origin issue-16-separate-config-paths
  gh pr create --base main --head issue-16-separate-config-paths \
    --title "Issue #16: 個人設定と共有設定の更新経路を分離" \
    --body-file /tmp/issue16-pr-body.md
  ```

  PR本文には概要、スコープ契約、テスト件数、Bash 3.2結果、独立レビュー結果、`Closes #16`を含める。PR作成後はマージせず、ユーザーへマージを依頼する。
