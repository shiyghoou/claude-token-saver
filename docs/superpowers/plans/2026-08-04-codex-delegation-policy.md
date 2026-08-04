# delegation-policy Codex Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 既存の `install.sh` / `uninstall.sh` で `delegation-policy` を Claude Code と Codex の両方へ安全に配置・明示実行・取り外しできるようにする。

**Architecture:** `skills/<name>/agents/openai.yaml` を Codex 対応の唯一の宣言とし、該当スキルだけを既存 `.claude/skills` に加えて `.agents/skills` へ配置する。台帳schemaは変えず、install時は実際に所有できた各destinationを別々に記録・gitignoreへ反映し、uninstall時は台帳の `name` / `src` と各destinationのlink targetまたはcopy markerを独立検証する。

**Tech Stack:** Bash 3.2互換shell、Python 3.6互換の既存台帳CLI、Markdown/YAML skills、依存ゼロの既存Bashテストランナー、Codex CLI smoke test。

## Global Constraints

- Issue #29の番号付きブランチ `issue-29-codex-delegation-policy` で作業し、`main`へ直接編集しない。
- `install.sh [--personal|--shared] [target]` と `uninstall.sh [--personal|--shared] [--guess] [target]` を変更しない。
- `CTS_NO_SYMLINK`、`CTS_STRICT`、`.token-saver/installed.json` の既存schemaを変更しない。
- Claude Codeのsettings、hook、skill配置、token-report、calibration、session-handoffの挙動を変更しない。
- Codex対応は `delegation-policy` の明示実行に限定し、Codex hook、自動handoff消費、Codex token計測を追加しない。
- `agents/openai.yaml` の `policy.allow_implicit_invocation` は必ず `false` とする。
- `.agents` または `.agents/skills` がsymlinkなら、personal install/uninstallは変更前に非0で拒否する。
- 利用者所有の同名file、directory、foreign symlinkは上書き・削除・gitignore登録しない。
- metadata、台帳、link target、copy markerのいずれかで所有権を証明できないuninstallはfail-closedで残す。
- 保護対象の未追跡Stage 4設計書2件は追加・変更・削除しない。
- 実装後は対象テスト、全体テスト、Python互換性、Bash 3.2 E2E、diff check、bounded Codex実機smokeを確認する。
- PRを作成してユーザーへマージを依頼し、エージェントはマージしない。

---

## File Structure

- Create: `skills/delegation-policy/agents/openai.yaml`
  - Codex対応宣言と暗黙起動禁止policyだけを持つ。
- Modify: `install.sh`
  - `.agents`親symlink拒否、destination共通配置、Codex対応スキルの追加配置、実所有pathだけのgitignore生成を担う。
- Modify: `uninstall.sh`
  - `.agents`親symlink拒否、Claude/Codex destinationの独立した所有権検証と安全な削除を担う。
- Modify: `test/test-delegation-policy.sh`
  - metadata、明示実行policy、README/設計文書のCodex契約を固定する。
- Modify: `test/test-install.sh`
  - Codex link/copy、metadata opt-in、同名保護、親symlink、scope分離、gitignoreを検証する。
- Modify: `test/test-uninstall.sh`
  - Codex link/copy削除、差し替え・metadata消失・台帳無し・親symlinkのfail-closedを検証する。
- Modify: `test/expected-min-count`
  - 追加24件を反映して総数563件、install 120件、uninstall 99件、delegation-policy 17件にする。
- Modify: `README.md`
  - 両runtimeの配置、`$delegation-policy`、`/skills`、非対応範囲を案内する。
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
  - 基礎設計へmetadata opt-inとCodex明示起動境界を追加する。
- Modify: `docs/specs/2026-07-31-token-saver-root-dir-design.md`
  - 当時未実装だったCodex adapterについて、Issue #29でskill配置のみ実装された現在状態を追記する。

---

### Task 1: Codex metadataと文書契約をテスト先行で固定する

**Files:**
- Create: `skills/delegation-policy/agents/openai.yaml`
- Modify: `test/test-delegation-policy.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: 既存 `skills/delegation-policy/SKILL.md` の `name: delegation-policy`。
- Produces: `skills/delegation-policy/agents/openai.yaml`。installerはこのfileの存在だけをCodex opt-inとして使う。

- [ ] **Step 1: metadata契約の失敗テストを2件追加する**

`test/test-delegation-policy.sh` に次を追加する。

```bash
OPENAI_METADATA="$REPO_ROOT/skills/delegation-policy/agents/openai.yaml"

test_Codex_metadataを持つ() {
  assert_file_exists "$OPENAI_METADATA" "Codex metadata"
  local body
  body="$(cat "$OPENAI_METADATA")"
  assert_contains "$body" "policy:" "policy root"
}

test_Codexの暗黙起動を禁止する() {
  local body
  body="$(cat "$OPENAI_METADATA")"
  assert_contains "$body" "allow_implicit_invocation: false" "explicit-only policy"
  assert_not_contains "$body" "allow_implicit_invocation: true" "implicit invocation"
}
```

- [ ] **Step 2: REDを確認する**

Run: `bash test/run.sh delegation-policy`

Expected: `skills/delegation-policy/agents/openai.yaml` が無いため、新規2件がFAILし、既存12件はPASSする。

- [ ] **Step 3: 最小metadataを追加する**

`skills/delegation-policy/agents/openai.yaml` を次の完全な内容で作る。

```yaml
policy:
  allow_implicit_invocation: false
```

- [ ] **Step 4: GREENを確認する**

Run: `bash test/run.sh delegation-policy`

Expected: 14/14 PASS。

- [ ] **Step 5: Task 1をコミットする**

`test/expected-min-count` の総数を534、`test-delegation-policy.sh`を14へ更新する。

```bash
git add skills/delegation-policy/agents/openai.yaml test/test-delegation-policy.sh test/expected-min-count
git commit -m "feat: delegation-policyのCodex metadataを追加"
```

### Task 2: Codex destinationへの安全なinstallを実装する

**Files:**
- Modify: `install.sh:97-114,431-553`
- Modify: `test/test-install.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: `skills/<name>/agents/openai.yaml` の存在、既存 `ledger.py add-skill/get-skill/list-skills`。
- Produces: `.agents/skills/<name>` のlinkまたはmarker付きcopy、`codex_installed_skills[]`、実配置pathだけを含むgitignore block。
- `cts_place_skill <name> <src> <dest> <runtime_label>` はglobal `placed_skill` と `placed_mode` を設定し、利用者所有物では両方を空にして警告する。
- `cts_destination_is_owned <src> <dest>` はlink target一致またはmarker付きdirectoryで0、それ以外で1を返す。

- [ ] **Step 1: installの失敗テストを10件追加する**

`test/test-install.sh` に次の10関数を追加する。

```bash
test_Codex対応スキルを_agentsへリンクする() {
  _setup_target
  _run_install
  assert_eq "0" "$INSTALL_STATUS" "終了コード"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/agents/openai.yaml"
  assert_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_Codex対応スキルをmarker付きcopyで配置する() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/.claude-token-saver"
}

test_metadata無しスキルを_agentsへ配置しない() {
  _setup_target
  _run_install
  assert_file_missing "$TARGET/.agents/skills/session-handoff"
  assert_file_missing "$TARGET/.agents/skills/token-report"
}

test_利用者所有のCodex同名directoryを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills/delegation-policy"
  printf '利用者のCodex方針\n' >"$TARGET/.agents/skills/delegation-policy/SKILL.md"
  _run_install
  assert_contains "$(cat "$TARGET/.agents/skills/delegation-policy/SKILL.md")" "利用者のCodex方針" "同名保護"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_利用者所有のCodex同名fileを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills"
  printf '利用者のfile\n' >"$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_contains "$(cat "$TARGET/.agents/skills/delegation-policy")" "利用者のfile" "同名file"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_利用者所有のCodex同名linkを上書きも除外もしない() {
  _setup_target
  mkdir -p "$TEST_TMP/user-skill" "$TARGET/.agents/skills"
  printf '利用者のlink\n' >"$TEST_TMP/user-skill/SKILL.md"
  ln -s "$TEST_TMP/user-skill" "$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_eq "$TEST_TMP/user-skill" "$(readlink "$TARGET/.agents/skills/delegation-policy")" "foreign link"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
}

test_agents_parent_symlinkは変更前に拒否する() {
  _setup_target
  mkdir -p "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.claude/settings.local.json"
  assert_file_missing "$TEST_TMP/outside/skills"
}

test_agents_skills_parent_symlinkは変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.agents" "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents/skills"
  _run_install
  assert_ne "0" "$INSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.claude/settings.local.json"
  assert_file_missing "$TEST_TMP/outside/delegation-policy"
}

test_personal後のsharedは実所有Codexスキルだけを除外する() {
  _setup_target
  bash "$INSTALL" --personal "$TARGET" >/dev/null 2>&1
  assert_file_missing "$TARGET/.gitignore"
  bash "$INSTALL" --shared "$TARGET" >/dev/null 2>&1
  assert_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/delegation-policy" ".gitignore"
  assert_not_contains "$(cat "$TARGET/.gitignore")" ".agents/skills/session-handoff" ".gitignore"
}

test_Codex同名衝突でもClaude側は従来どおり配置する() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills/delegation-policy"
  printf '利用者のCodex方針\n' >"$TARGET/.agents/skills/delegation-policy/SKILL.md"
  _run_install
  assert_file_exists "$TARGET/.claude/skills/delegation-policy/SKILL.md"
  assert_contains "$(cat "$TARGET/.token-saver/installed.json")" '"name": "delegation-policy"' "台帳"
}
```

- [ ] **Step 2: REDを確認する**

Run: `bash test/run.sh test-install.sh`

Expected: 新規Codex配置・親symlink拒否・Codex gitignore観点がFAILし、既存107件はPASSする。

- [ ] **Step 3: managed parentの事前検査を拡張する**

`cts_reject_managed_symlinks` の先頭へ次の2pathを追加し、既存personal変更より前に検査される状態を保つ。

```bash
    "$TARGET/.agents" \
    "$TARGET/.agents/skills" \
```

- [ ] **Step 4: destination共通配置関数を追加する**

既存 `looks_like_our_link` をskill loop内から `warn` の直後にある共通helper領域へ移す。その直後へ、配列をsubshellで失わない次のglobal-result型関数を追加する。`cts_destination_is_owned` はpersonal block外の `--shared` 経路からも呼べる位置に置く。

```bash
cts_place_skill() {
  local name="$1" src="$2" dest="$3" runtime_label="$4" link recorded
  placed_skill=""
  placed_mode=""

  if [ -z "${CTS_NO_SYMLINK:-}" ] && [ -L "$dest" ] &&
     [ "$(readlink "$dest")" = "$src" ]; then
    placed_skill=1
    placed_mode=link
    return 0
  fi
  if [ -L "$dest" ]; then
    link="$(readlink "$dest")"
    recorded="$(python3 "$CTS_HOME/lib/ledger.py" get-skill "$LEDGER" "$name" | cut -d $'\037' -f1)"
    if [ "$link" != "$recorded" ] &&
       { [ -n "$recorded" ] || ! looks_like_our_link "$link" "$name"; }; then
      warn "$runtime_label スキル $name は導入先が張ったリンクなので触らない（$link）"
      return 0
    fi
  elif [ -d "$dest" ]; then
    if [ ! -f "$dest/.claude-token-saver" ]; then
      warn "$runtime_label スキル $name は導入先に既存のディレクトリがあるため触らない（.gitignore にも書かない）"
      return 0
    fi
  elif [ -e "$dest" ]; then
    warn "$runtime_label スキル $name は導入先に既存のファイルがあるため触らない（.gitignore にも書かない）"
    return 0
  fi

  rm -rf "$dest"
  placed_mode=link
  if [ -z "${CTS_NO_SYMLINK:-}" ] && ln -s "$src" "$dest" 2>/dev/null; then
    info "  $runtime_label スキルをリンクした: $name"
  else
    cp -R "$src" "$dest" || die "$runtime_label スキル $name を配置できない"
    printf 'claude-token-saver が配置したコピー。手で編集しない。\n' >"$dest/.claude-token-saver"
    placed_mode=copy
    info "  $runtime_label スキルをコピーで配置した: $name"
  fi
  placed_skill=1
}

cts_destination_is_owned() {
  local src="$1" dest="$2"
  { [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; } ||
    { [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; }
}
```

- [ ] **Step 5: skill loopを2destinationへ接続する**

`installed_skills=()` の隣に `claude_installed_skills=()` と `codex_installed_skills=()` を置く。personal scopeでは `.claude/skills` を常に作り、Codex metadataが1件でもある現在のsourceでは `.agents/skills` も作る。各skillで次の順に配置し、少なくとも一方を所有できた場合だけ既存schemaへ1 recordを書き込む。

```bash
installed_any=""
ledger_mode=""
cts_place_skill "$name" "$src" "$TARGET/.claude/skills/$name" "Claude Code"
if [ -n "$placed_skill" ]; then
  claude_installed_skills+=("$name")
  installed_any=1
  ledger_mode="$placed_mode"
fi

if [ -f "$src/agents/openai.yaml" ]; then
  mkdir -p "$TARGET/.agents/skills" || die "Codex skills ディレクトリを作成できない"
  cts_place_skill "$name" "$src" "$TARGET/.agents/skills/$name" "Codex"
  if [ -n "$placed_skill" ]; then
    codex_installed_skills+=("$name")
    installed_any=1
    [ -n "$ledger_mode" ] || ledger_mode="$placed_mode"
  fi
fi

if [ -n "$installed_any" ]; then
  python3 "$CTS_HOME/lib/ledger.py" add-skill "$LEDGER" "$name" "$src" "$ledger_mode" ||
    die "台帳を更新できない"
  installed_skills+=("$name")
fi
```

- [ ] **Step 6: shared-onlyとgitignoreを実所有path基準にする**

`--shared` の `list-skills` loopは `name src mode` を読み、次のように両destinationを実検査する。default installでは配置時に作った2配列をそのまま使う。

```bash
if cts_destination_is_owned "$src" "$TARGET/.claude/skills/$name"; then
  claude_installed_skills+=("$name")
fi
if [ -f "$src/agents/openai.yaml" ] &&
   cts_destination_is_owned "$src" "$TARGET/.agents/skills/$name"; then
  codex_installed_skills+=("$name")
fi
```

gitignore blockのskill部分を次へ置き換える。

```bash
for name in ${claude_installed_skills[@]+"${claude_installed_skills[@]}"}; do
  printf '.claude/skills/%s\n' "$name"
done
for name in ${codex_installed_skills[@]+"${codex_installed_skills[@]}"}; do
  printf '.agents/skills/%s\n' "$name"
done
```

- [ ] **Step 7: GREENと既存Claude契約を確認する**

Run: `bash test/run.sh test-install.sh`

Expected: 120/120 PASS。

Run: `bash test/run.sh delegation-policy`

Expected: 14/14 PASS。

- [ ] **Step 8: Task 2をコミットする**

`test/expected-min-count` の総数を547、`test-install.sh`を120へ更新する。

```bash
git add install.sh test/test-install.sh test/expected-min-count
git commit -m "feat: Codex対応スキルを安全に配置"
```

### Task 3: Codex destinationのfail-closed uninstallを実装する

**Files:**
- Modify: `uninstall.sh:102-119,245-337,342-410`
- Modify: `test/test-uninstall.sh`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: 台帳の既存 `name` / `src`、sourceの `agents/openai.yaml`、destinationの実file type/link target/copy marker。
- Produces: Claude/Codex destinationごとの削除または警告。どちらかを残した場合は `skills_left=1` とし、台帳とgitignore blockを保持する。
- `remove_skill_destination <name> <src> <dest> <runtime_label>` は所有権を確認したdestinationだけを削除する。

- [ ] **Step 1: uninstallの失敗テストを9件追加する**

`test/test-uninstall.sh` に次を追加する。

```bash
test_Codexスキルのlinkを外す() {
  _setup_target
  _run_install
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.agents/skills/delegation-policy"
}

test_Codexスキルのmarker付きcopyを外す() {
  _setup_target
  CTS_NO_SYMLINK=1 bash "$INSTALL" "$TARGET" >/dev/null 2>&1
  _run_uninstall
  assert_eq "0" "$UNINSTALL_STATUS" "終了コード"
  assert_file_missing "$TARGET/.agents/skills/delegation-policy"
}

test_差し替えられたCodexスキルは残して台帳と除外を保持する() {
  _setup_target
  _run_install
  rm "$TARGET/.agents/skills/delegation-policy"
  mkdir -p "$TARGET/.agents/skills/delegation-policy"
  printf '差し替え\n' >"$TARGET/.agents/skills/delegation-policy/SKILL.md"
  _run_uninstall
  assert_contains "$(cat "$TARGET/.agents/skills/delegation-policy/SKILL.md")" "差し替え" "利用者所有物"
  assert_file_exists "$TARGET/.token-saver/installed.json"
  assert_contains "$(_gitignore_text)" ".agents/skills/delegation-policy" ".gitignore"
}

test_source_metadata消失時はCodexスキルを残す() {
  _setup_target
  local clone="$TEST_TMP/source-clone"
  _clone_repo "$clone"
  bash "$clone/install.sh" "$TARGET" >/dev/null 2>&1
  rm "$clone/skills/delegation-policy/agents/openai.yaml"
  bash "$clone/uninstall.sh" "$TARGET" >"$TEST_TMP/.out" 2>"$TEST_TMP/.err"
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
  assert_contains "$(cat "$TEST_TMP/.out")$(cat "$TEST_TMP/.err")" "metadata" "警告"
  assert_file_exists "$TARGET/.token-saver/installed.json"
}

test_台帳無しではCodexスキルを推測削除しない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills"
  ln -s "$REPO_ROOT/skills/delegation-policy" "$TARGET/.agents/skills/delegation-policy"
  _run_uninstall
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
}

test_guessでもCodexスキルを推測削除しない() {
  _setup_target
  mkdir -p "$TARGET/.agents/skills"
  ln -s "$REPO_ROOT/skills/delegation-policy" "$TARGET/.agents/skills/delegation-policy"
  _run_uninstall_guess
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
}

test_uninstallは_agents_parent_symlinkを変更前に拒否する() {
  _setup_target
  mkdir -p "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents"
  _run_uninstall
  assert_ne "0" "$UNINSTALL_STATUS" "終了コード"
  assert_file_exists "$TARGET/.agents"
}

test_uninstallは_agents_skills_parent_symlinkを変更前に拒否する() {
  _setup_target
  mkdir -p "$TARGET/.agents" "$TEST_TMP/outside"
  ln -s "$TEST_TMP/outside" "$TARGET/.agents/skills"
  _run_uninstall
  assert_ne "0" "$UNINSTALL_STATUS" "終了コード"
  assert_file_exists "$TARGET/.agents/skills"
  assert_file_missing "$TEST_TMP/outside/delegation-policy"
}

test_Codexスキルは_install_uninstall_installで再導入できる() {
  _setup_target
  _run_install
  _run_uninstall
  assert_file_missing "$TARGET/.agents/skills/delegation-policy"
  _run_install
  assert_file_exists "$TARGET/.agents/skills/delegation-policy/SKILL.md"
}
```

- [ ] **Step 2: REDを確認する**

Run: `bash test/run.sh test-uninstall.sh`

Expected: Codex destinationが現状のuninstaller対象外なので新規削除・保護観点がFAILし、既存86件はPASSする。

- [ ] **Step 3: managed parentの事前検査を拡張する**

installと同じ順序で `cts_reject_managed_symlinks` へ追加する。

```bash
    "$TARGET/.agents" \
    "$TARGET/.agents/skills" \
```

- [ ] **Step 4: destination別削除関数へ分離する**

既存 `remove_skill` の所有権検査を次の関数へ移し、destinationとruntime labelを引数にする。

```bash
remove_skill_destination() {
  local name="$1" src="$2" dest="$3" runtime_label="$4"
  if [ -L "$dest" ]; then
    if [ -z "$src" ]; then
      warn "$runtime_label スキル $name の記録にリンク先が無いため触らない"
      skills_left=1
      return 0
    fi
    if [ "$(readlink "$dest")" = "$src" ]; then
      rm -f "$dest"
      info "  $runtime_label スキルのリンクを外した: $name"
      return 0
    fi
  elif [ -d "$dest" ] && [ -f "$dest/.claude-token-saver" ]; then
    rm -rf "$dest"
    info "  $runtime_label スキルのコピーを削除した: $name"
    return 0
  elif [ ! -e "$dest" ]; then
    return 0
  fi
  warn "$runtime_label スキル $name は導入後に差し替えられているので残す"
  skills_left=1
}
```

path-safe name検査後、`remove_skill` からClaude destinationを必ず検査し、Codex destinationが存在する場合だけmetadataを確認する。

```bash
remove_skill_destination "$name" "$src" "$TARGET/.claude/skills/$name" "Claude Code"

codex_dest="$TARGET/.agents/skills/$name"
if [ -e "$codex_dest" ] || [ -L "$codex_dest" ]; then
  if [ -z "$src" ] || [ ! -f "$src/agents/openai.yaml" ]; then
    warn "Codex スキル $name のsource metadataを確認できないため残す"
    skills_left=1
  else
    remove_skill_destination "$name" "$src" "$codex_dest" "Codex"
  fi
fi
```

- [ ] **Step 5: 台帳無し・guess・shared cleanupをCodex pathへ広げる**

台帳が無いときは `.claude/skills` と `.agents/skills` を別々に確認する。`--guess` は従来のClaude pathだけを対象とし、Codex pathが残っていれば警告して `skills_left=1` にする。shared側の残存確認も、台帳の各 `src` に対して両destinationを調べる。

```bash
if [ -d "$TARGET/.agents/skills" ] &&
   [ -n "$(find "$TARGET/.agents/skills" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  warn "台帳で所有権を確認できないため .agents/skills を変更していない"
  skills_left=1
fi
```

所有物を全て外せた場合だけ空directoryを片付ける。

```bash
rmdir "$TARGET/.agents/skills" 2>/dev/null || true
rmdir "$TARGET/.agents" 2>/dev/null || true
```

- [ ] **Step 6: GREENと往復を確認する**

Run: `bash test/run.sh test-uninstall.sh`

Expected: 99/99 PASS。

Run: `bash test/run.sh test-install.sh`

Expected: 120/120 PASS。

- [ ] **Step 7: Task 3をコミットする**

`test/expected-min-count` の総数を560、`test-uninstall.sh`を99へ更新する。

```bash
git add uninstall.sh test/test-uninstall.sh test/expected-min-count
git commit -m "feat: Codexスキルを安全に取り外す"
```

### Task 4: Codex利用手順と対応境界を文書へ同期する

**Files:**
- Modify: `test/test-delegation-policy.sh`
- Modify: `README.md`
- Modify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Modify: `docs/specs/2026-07-31-token-saver-root-dir-design.md`
- Modify: `test/expected-min-count`

**Interfaces:**
- Consumes: `.agents/skills/delegation-policy` と `allow_implicit_invocation: false`。
- Produces: Codex CLI/IDEでの `$delegation-policy` 明示実行、`/skills` discovery確認、非対応範囲の利用者向け契約。

- [ ] **Step 1: 文書契約の失敗テストを3件追加する**

`test/test-delegation-policy.sh`へ次を追加する。

```bash
test_READMEはCodexの配置と明示実行を案内する() {
  local body
  body="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$body" ".agents/skills/delegation-policy" "Codex配置"
  assert_contains "$body" '$delegation-policy' "明示実行"
  assert_contains "$body" '`/skills`' "skill一覧"
}

test_READMEはCodex対応範囲を限定する() {
  local body
  body="$(cat "$REPO_ROOT/README.md")"
  assert_contains "$body" "暗黙起動" "explicit-only"
  assert_contains "$body" "Codex用フック" "hook非対応"
  assert_contains "$body" "handoff" "handoff非対応"
  assert_contains "$body" "token-report" "計測非対応"
}

test_設計文書はCodex_adapterの現在状態を示す() {
  local base root_design
  base="$(cat "$REPO_ROOT/docs/specs/2026-07-31-claude-token-saver-design.md")"
  root_design="$(cat "$REPO_ROOT/docs/specs/2026-07-31-token-saver-root-dir-design.md")"
  assert_contains "$base" "agents/openai.yaml" "Codex opt-in"
  assert_contains "$base" "allow_implicit_invocation: false" "明示起動"
  assert_contains "$root_design" "Issue #29" "現在状態"
  assert_contains "$root_design" "スキル配置だけ" "adapter境界"
}
```

- [ ] **Step 2: REDを確認する**

Run: `bash test/run.sh delegation-policy`

Expected: 現READMEの「Codex側のアダプタが別途必要」という旧状態と、設計文書の現在状態不足により新規3件がFAILする。

- [ ] **Step 3: READMEを更新する**

導入手順を次の現在形へ直す。

```markdown
2. `skills/` 配下を Claude Code の `.claude/skills/<name>` へ配置する。
   `agents/openai.yaml` を持つスキルだけは、Codex の
   `.agents/skills/<name>` にも配置する。
```

配置treeへ次を追加する。

```text
  .agents/
    skills/delegation-policy  ← Codex用。暗黙起動は禁止
```

委譲判断節へ次の利用契約を追記する。

```markdown
Codex CLI / IDEでは `$delegation-policy` と指定して明示実行する。利用可能な
skillは `/skills` で確認できる。`agents/openai.yaml` で暗黙起動を禁止しているため、
通常の会話へ自動適用されない。

このCodex対応は委譲判断skillの発見と明示実行だけを対象とする。Codex用フック、
handoffの自動消費、token-reportによるCodex使用量計測は提供しない。
```

- [ ] **Step 4: 2つの基礎設計を同期する**

`docs/specs/2026-07-31-claude-token-saver-design.md` のskill配布節へmetadata opt-in、両destination、explicit-only、非対応範囲を追記する。

`docs/specs/2026-07-31-token-saver-root-dir-design.md` の冒頭に現在状態注記を追加し、当時のスコープを改変せず後続Issueを明示する。

```markdown
> **現在状態（Issue #29）:** `delegation-policy` は `agents/openai.yaml` を宣言し、
> `.agents/skills` へも配置される。これはスキル配置だけのCodex adapterであり、
> hook、handoff自動消費、token計測は本設計当時と同じく未対応である。
```

- [ ] **Step 5: GREENを確認する**

Run: `bash test/run.sh delegation-policy`

Expected: 17/17 PASS。

- [ ] **Step 6: Task 4をコミットする**

`test/expected-min-count` の総数を563、`test-delegation-policy.sh`を17へ更新する。

```bash
git add README.md docs/specs/2026-07-31-claude-token-saver-design.md docs/specs/2026-07-31-token-saver-root-dir-design.md test/test-delegation-policy.sh test/expected-min-count
git commit -m "docs: Codexでの明示実行手順を追加"
```

### Task 5: 全回帰と実Codex smokeを検証する

**Files:**
- Verify: `skills/delegation-policy/agents/openai.yaml`
- Verify: `install.sh`
- Verify: `uninstall.sh`
- Verify: `test/test-delegation-policy.sh`
- Verify: `test/test-install.sh`
- Verify: `test/test-uninstall.sh`
- Verify: `README.md`
- Verify: `docs/specs/2026-07-31-claude-token-saver-design.md`
- Verify: `docs/specs/2026-07-31-token-saver-root-dir-design.md`
- Verify: `test/expected-min-count`

**Interfaces:**
- Consumes: Tasks 1-4の全変更。
- Produces: 563/563回帰証拠、互換性証拠、実Codex明示実行証拠、レビュー可能な実diff。

- [ ] **Step 1: shell構文と対象テストを実行する**

Run: `bash -n install.sh uninstall.sh test/test-install.sh test/test-uninstall.sh test/test-delegation-policy.sh`

Expected: exit 0、標準エラー空。

Run: `bash test/run.sh delegation-policy`

Expected: 17/17 PASS。

Run: `bash test/run.sh test-install.sh`

Expected: 120/120 PASS。

Run: `bash test/run.sh test-uninstall.sh`

Expected: 99/99 PASS。

- [ ] **Step 2: 全体回帰を実行する**

Run: `CTS_NO_SKIP=1 bash test/run.sh`

Expected: 563/563 PASS、FAIL 0、SKIP 0、件数下限を満たす。

- [ ] **Step 3: PythonとBash 3.2互換性を実行する**

Run: `bash test/test-python-compatibility.sh`

Expected: exit 0。

Run: `bash test/bash32-e2e.sh`

Expected: exit 0。

- [ ] **Step 4: 一時repositoryでinstall往復を実証する**

```bash
smoke_root="$(mktemp -d)"
trap 'rm -rf -- "$smoke_root"' EXIT
git -C "$smoke_root" init -q
bash ./install.sh "$smoke_root"
test -f "$smoke_root/.agents/skills/delegation-policy/SKILL.md"
grep -F 'allow_implicit_invocation: false' "$smoke_root/.agents/skills/delegation-policy/agents/openai.yaml"
bash ./uninstall.sh "$smoke_root"
test ! -e "$smoke_root/.agents/skills/delegation-policy"
```

Expected: 全command exit 0。検証後に作成した一時directoryだけを削除する。

- [ ] **Step 5: bounded Codex実機smokeを実行する**

新しい一時Git repositoryへinstallし、そのrepositoryをworking directoryとしてinstalled Codex CLIをtimeout付きで1回だけ起動する。promptは次を使う。

```text
$delegation-policy 次の作業を委譲すべきか判断し、decision, reason, delegated scope, capability tier, completion condition, collection method の6項目だけを返してください。作業: README内の1語を検索する。
```

Expected: timeout内にexit 0で完了し、出力に6 fieldがすべて存在する。認証・network・model availabilityで実行不能ならcontract testの成功と混同せず、環境blockerと実出力をPRへ記録する。

- [ ] **Step 6: 実diffと保護対象を確認する**

Run: `git diff --check main...HEAD`

Expected: outputなし、exit 0。

Run: `git diff --stat main...HEAD && git status --short --branch`

Expected: Issue #29の予定filesだけが変更され、Stage 4の未追跡設計書2件はuntrackedのまま内容不変。

- [ ] **Step 7: 検証証拠をコミット状態へ固定する**

テストで修正が生じた場合だけ対象fileを明示してコミットする。変更が無ければ空commitを作らない。

```bash
git status --short
git log --oneline main..HEAD
```

Expected: 予定外のtracked変更なし。

### Task 6: 新しい独立レビューとPR handoffを完了する

**Files:**
- Review only: `main...HEAD` の全diff
- External write: GitHub Issue #29 / 新規PR

**Interfaces:**
- Consumes: Task 5のdiffと検証証拠。
- Produces: fresh reviewerの `ship` / `fix-first` / `rethink` 判定、必要修正の再検証、Issue #29を閉じるPR。

- [ ] **Step 1: 実装者と異なるfresh reviewerへ全diffを渡す**

review依頼にはIssue #29、承認済み設計、公開API不変、台帳schema不変、親symlink拒否、同名保護、metadata消失fail-closed、全テスト結果、Codex smoke出力を含める。

Expected: reviewerが `ship`、`fix-first`、`rethink` のいずれかと、file/line根拠を返す。

- [ ] **Step 2: 指摘があればTDDで修正して再レビューする**

`fix-first` は指摘を再現する失敗テストを先に追加し、最小修正、対象テスト、全体回帰の順に実行する。`rethink` は実装を止め、設計差分をユーザーへ提示する。修正後は同じreviewerの追認ではなく、新しいfresh reviewを取得する。

Expected: 最終判定 `ship`、未解決のactionable finding 0件。

- [ ] **Step 3: branchをpushしてPRを作成する**

PR titleは `delegation-policyをCodexの明示実行に対応` とし、bodyへ次を記載する。

```markdown
Closes #29

## 概要
- Codex対応metadataを持つskillだけを `.agents/skills` へ安全に配置
- 既存台帳schemaのままClaude/Codex destinationを独立検証して取り外し
- `$delegation-policy` の明示実行手順と非対応範囲を文書化

## 検証
- 対象テスト件数
- `CTS_NO_SKIP=1 bash test/run.sh` の結果
- Python互換性 / Bash 3.2 E2E
- bounded Codex smokeの結果
- fresh reviewの最終判定
```

- [ ] **Step 4: CIを確認してマージ依頼で停止する**

Expected: 必須checkが全て成功し、merge可能状態。PR URL、commit、CI、review、残る環境制約をユーザーへ報告し、マージは行わない。
