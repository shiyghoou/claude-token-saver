#!/usr/bin/env python3
# settings.local.json のフック登録を書き換える。
#
#   settings-hooks.py install <path> --ledger <ledger> [--matcher EVENT=REGEX] <event>:<command> ...
#   settings-hooks.py remove  <path> [--ledger <ledger>] [--guess]
#   settings-hooks.py validate-codex <path> --ledger <ledger>
#   settings-hooks.py same    <path> <other>   # 2つの設定がデータとして同値か
#
# 終了コード: 0=処理した / 1=失敗（何も変更していない） / 2=警告（何も変更していない）
#
# install も remove も、まず「自分のフック」を全部外す。install はそのうえで
# 入れ直す。コマンド文字列の完全一致だけで冪等性を取ると、シンボリックリンク
# 経由と実パス経由で二重登録され、クローンを移動すれば存在しないパスを指す
# 登録が残る。総入れ替えすれば、綴り違いも移動後の残骸も同時に消える。
#
# 「自分のもの」の同定は台帳（置き場所は scripts/lib/paths.sh が決める）を正とする。
# 台帳に記録が無いときは既定で何もしない（fail-closed）。ファイル名での推測は
# 利用者が自作した同名スクリプトを巻き込んで消しうるため、明示的な --guess を
# 与えたときだけ通す。「台帳ファイルが在る」ことを「記録が在る」と取り違えると、
# 記録ゼロの台帳で推測へ落ち、利用者のフックを消してしまう。
#
# 判定を install/uninstall で二重に実装しないため、双方がこれを呼ぶ。

import json
import os
import re
import shlex
import sys

# 導入先から呼ばれる道具である。クローンに __pycache__ を書き散らさない。
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402  (同ディレクトリの小道具)

# 台帳が無いときに、自分のものと推測するフックスクリプトのファイル名。
OURS = {"handoff-check.sh", "suggest-session-cut.sh"}
LEDGER_KEYS = {"hooks", "codex_hooks"}
CODEX_EVENT = "SessionStart"
CODEX_MATCHER = "startup|clear"
CODEX_ADDITIONAL_CONTEXT_LIMIT = 10000


def looks_like_ours(command):
    """台帳が無いときの推測。実行ファイル位置だけを候補にする。

    先頭トークンの basename だけでは取りこぼす:
      - 空白入りパスが非クォートで登録されている（旧版の登録）
      - `bash /path/handoff-check.sh` のようにインタプリタ経由
      - Windows のバックスラッシュ区切り
    先頭トークン、または bash/sh/python などのインタプリタ直後だけを見る。
    `echo handoff-check.sh` のような利用者の説明文を自分のフックと誤認しない。
    旧版が空白入りパスを非クォートで保存した場合だけ、パスらしい文字列が
    自分のスクリプト名で終わる形を互換用に受け入れる。
    """
    text = str(command).replace("\\", "/")

    candidates = [text.split()]
    for posix in (True, False):
        try:
            candidates.append(shlex.split(text, posix=posix))
        except ValueError:
            pass

    interpreters = {
        "bash", "sh", "dash", "zsh", "ksh", "fish", "python", "python3",
    }
    for parts in candidates:
        if not parts:
            continue
        if os.path.basename(parts[0].strip("'\"")) in OURS:
            return True
        if len(parts) > 1 and os.path.basename(parts[0].strip("'\"")) in interpreters:
            if os.path.basename(parts[1].strip("'\"")) in OURS:
                return True

    # 旧版の非クォート登録（例: /tmp/my clone/scripts/handoff-check.sh）を
    # 取り外せるようにする。ただしコマンド名が先頭に無い文字列だけを対象にし、
    # `echo .../handoff-check.sh` は候補にしない。
    first = text.lstrip().split(None, 1)[0] if text.lstrip() else ""
    if first.startswith(("/", "./", "../")) or (len(first) >= 2 and first[1] == ":"):
        return any(text.rstrip().endswith("/" + name) for name in OURS)
    return False


def load(path):
    """(data, original_text) を返す。読めない・壊れている場合は落ちる。"""
    if not os.path.lexists(path):
        return {}, None
    try:
        # 原文のBOMを保持する。解析時だけ取り除かないと、利用者のBOM付き
        # JSONを再保存したときにBOMを失い、変更していない前置きを壊してしまう。
        with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
            original = f.read()
        text = original.lstrip("\ufeff").strip()
        data = json.loads(text) if text else {}
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        # 壊れたファイルを上書きすると、利用者の既存設定を失う。何もせず落ちる。
        sys.stderr.write(
            "既存の %s が妥当な JSON でない (%s)。\n"
            "手で直してから実行せよ。設定は変更していない。\n" % (path, e)
        )
        sys.exit(1)
    if not isinstance(data, dict):
        sys.stderr.write("既存の %s の最上位がオブジェクトでない。設定は変更していない。\n" % path)
        sys.exit(1)
    if "hooks" in data and not isinstance(data["hooks"], dict):
        sys.stderr.write("既存の %s の hooks がオブジェクトでない。設定は変更していない。\n" % path)
        sys.exit(1)
    for event, groups in data.get("hooks", {}).items():
        if not isinstance(event, str) or not isinstance(groups, list):
            sys.stderr.write("既存の %s の hooks イベントが配列でない。設定は変更していない。\n" % path)
            sys.exit(1)
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                sys.stderr.write("既存の %s の hooks グループが妥当でない。設定は変更していない。\n" % path)
                sys.exit(1)
            for entry in group["hooks"]:
                if not isinstance(entry, dict) or (
                    "command" in entry and not isinstance(entry["command"], str)
                ):
                    sys.stderr.write("既存の %s の hooks エントリが妥当でない。設定は変更していない。\n" % path)
                    sys.exit(1)
    return data, original


def recorded_hooks(ledger_path, ledger_key="hooks"):
    """台帳に記録された登録コマンドを返す。記録が無ければ None を返す。

    空リスト（「登録すべきフックが1つも無かった」という記録）と、記録そのものが
    無い状態を区別する。前者は「外すものは無い」で正しく、後者は推測しか
    残っていない状態であり、既定では何もしてはならない。
    """
    if not ledger_path or not ledger.has_record(ledger_path, ledger_key):
        return None
    return [
        h for h in ledger.get_list(ledger.load(ledger_path), ledger_key) if isinstance(h, str)
    ]


def codex_managed_positions(data, known):
    """厳格なCodex managed entryの位置を1件だけ返す。失敗時はNone。

    Codex側はcommand文字列だけで所有権を推測してはならない。同じ文字列を
    利用者が別eventへ移した場合や、matcher/type/limitを変えた場合に、
    uninstallが利用者のhookを消すためである。groupとentryの余分なmetadataも
    所有権の証拠にならないため、installerが生成する構造そのものを要求する。
    同じcommandの出現が1件を超えたときも、どれがmanagedか確定できないので
    fail-closedにする。
    """
    if not isinstance(known, list) or len(known) != 1 or not isinstance(known[0], str):
        return None
    command = known[0]
    hooks = data.get("hooks") if isinstance(data, dict) else None
    if not isinstance(hooks, dict):
        return None

    positions = []
    command_count = 0
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            for entry_index, entry in enumerate(group["hooks"]):
                if not isinstance(entry, dict) or entry.get("command") != command:
                    continue
                command_count += 1
                exact_group = (
                    event == CODEX_EVENT
                    and set(group.keys()) == {"matcher", "hooks"}
                    and group.get("matcher") == CODEX_MATCHER
                )
                exact_entry = (
                    set(entry.keys()) == {"type", "command", "additionalContextLimit"}
                    and entry.get("type") == "command"
                    and isinstance(entry.get("additionalContextLimit"), int)
                    and not isinstance(entry.get("additionalContextLimit"), bool)
                    and entry.get("additionalContextLimit") == CODEX_ADDITIONAL_CONTEXT_LIMIT
                )
                if exact_group and exact_entry:
                    positions.append((event, group_index, entry_index))

    if command_count != 1 or len(positions) != 1:
        return None
    return positions


def _purge_positions(data, positions):
    """指定位置だけをCodex設定から外し、外した件数を返す。"""
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    wanted = set(positions)
    removed = 0
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        event_removed = 0
        kept_groups = []
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            inner = group["hooks"]
            kept = [
                entry
                for entry_index, entry in enumerate(inner)
                if (event, group_index, entry_index) not in wanted
            ]
            event_removed += len(inner) - len(kept)
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)
        removed += event_removed
        if kept_groups:
            hooks[event] = kept_groups
        elif event_removed:
            del hooks[event]
    if not hooks and removed:
        del data["hooks"]
    return removed


def purge(data, known, guess=False, ledger_key="hooks"):
    """自分のフック登録をすべて外し、外した件数を返す。

    known が None でなければ（＝台帳に記録が在れば）、Claude側はそれとの完全一致だけを
    外す。台帳がある以上、自分が書いていないものへ手を出す理由が無い。Codex側は
    command一致ではなく codex_managed_positions() のstrict構造一致だけを外す。
    記録が無いときは、guess を明示されたときだけ推測へ落ちる。

    グループ単位ではなくフック単位で外す。matcher 付きのグループに利用者が
    自分のフックを同居させている場合、グループごと落とすとそれを巻き込む。
    """
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return 0

    if ledger_key == "codex_hooks":
        positions = codex_managed_positions(data, known)
        if positions is None:
            return 0
        return _purge_positions(data, positions)

    def is_ours(entry):
        if not isinstance(entry, dict):
            return False
        command = entry.get("command", "")
        if known is not None:
            return str(command) in known
        return guess and looks_like_ours(command)

    removed = 0
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue

        event_removed = 0
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            inner = group["hooks"]
            kept = [h for h in inner if not is_ours(h)]
            event_removed += len(inner) - len(kept)
            # 中身が空になったグループは install.sh が作ったものなので落とす。
            if kept:
                group["hooks"] = kept
                kept_groups.append(group)

        removed += event_removed
        if kept_groups:
            hooks[event] = kept_groups
        elif event_removed:
            del hooks[event]
        # 元から空だったイベントは残す。明示的な空は利用者の設定意図である。

    if not hooks and removed:
        del data["hooks"]
    return removed


def guess_candidates(data):
    """台帳が無い install で、推測なら候補になる登録を列挙する。"""
    candidates = []
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return candidates
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            for entry in group["hooks"]:
                if isinstance(entry, dict) and looks_like_ours(entry.get("command", "")):
                    candidates.append((event, entry.get("command", "")))
    return candidates


def save_if_changed(path, data, original):
    """内容が変わったときだけ書き戻す。

    テキストの一致ではなくデータの同値で判定する。正規形と違うだけで書くと、
    一度も導入していない利用者のファイルを取り外しのついでに再整形してしまう。
    """
    if original is not None:
        try:
            if json.loads(original.lstrip("\ufeff").strip() or "{}") == data:
                return False
        except json.JSONDecodeError:
            pass
    bom = "\ufeff" if original is not None and original.startswith("\ufeff") else ""
    new_text = bom + json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    if new_text == original:
        return False
    ledger.write_atomic(path, new_text)
    return True


def cmd_install(path, ledger_path, ledger_key, specs, matchers, additional_limits):
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
    for event in additional_limits:
        if event not in events:
            sys.stderr.write("追加コンテキスト上限のイベントがフック指定に無い: %s\n" % event)
            return 64

    data, original = load(path)
    known = recorded_hooks(ledger_path, ledger_key)
    candidates = [] if known is not None else guess_candidates(data)
    # 台帳が無い install も推測削除へ落とさない。旧版の残骸は二重登録のまま
    # 残りうるが、利用者のフックを消すより安全である。候補だけを警告する。
    if candidates:
        for event, command in candidates:
            sys.stderr.write(
                "  警告: 台帳が無いため推測候補のフックを変更していない: %s [%s]\n"
                % (event, command)
            )
    removed = purge(data, known, guess=False, ledger_key=ledger_key)

    added = []
    commands = []
    hooks = data.setdefault("hooks", {})
    for event, command in parsed_specs:
        # 空白を含むパスをそのまま入れると、シェルが単語分割して毎セッション
        # rc=127 で失敗する。クォートしてから登録する。
        quoted = shlex.quote(command)
        entry = {"type": "command", "command": quoted}
        if event in additional_limits:
            entry["additionalContextLimit"] = additional_limits[event]
        group = {"hooks": [entry]}
        if event in matchers:
            group["matcher"] = matchers[event]
        hooks.setdefault(event, []).append(group)
        commands.append(quoted)
        added.append("%s → %s" % (event, os.path.basename(command)))

    # 台帳には、登録した文字列そのものを残す。次回の同定を推測に頼らせない。
    if ledger_path:
        led = ledger.load(ledger_path)
        led[ledger_key] = commands
        try:
            ledger.save(ledger_path, led)
        except OSError as e:
            # 台帳が書けないなら、次回の取り外しは推測しか残らない。
            # 設定だけ書いて先へ進めるのは、取り外せない状態を作ることである。
            sys.stderr.write("台帳を書けない (%s): %s\n" % (ledger_path, e))
            return 1

    if not save_if_changed(path, data, original):
        print("  フックは既に登録済み")
        return 2 if candidates else 0

    for line in added:
        print("  フックを登録した: %s" % line)
    stale = removed - len(added)
    if stale > 0:
        print("  古い・重複したフックの登録を %d 件整理した" % stale)
    return 2 if candidates else 0


def cmd_remove(path, ledger_path, ledger_key="hooks", guess=False):
    if not os.path.exists(path):
        print("  settings.local.json が無い")
        return 0
    # 壊れた JSON はここで落とす。fail-closed の判定より先に読むのは、
    # 「記録が無いから何もしない」で壊れたファイルを見逃さないためである。
    data, original = load(path)
    known = recorded_hooks(ledger_path, ledger_key)
    if known is None and not guess:
        sys.stderr.write(
            "  警告: 台帳にフックの記録が無いため settings.local.json を変更しない。\n"
            "        どれが自分の登録か分からない状態で消すと、利用者のフックを\n"
            "        巻き込む。台帳の無い旧版で導入した環境では --guess を付けて\n"
            "        実行せよ（ファイル名で推測する）。\n"
        )
        return 2
    if ledger_path and ledger_key == "codex_hooks":
        ledger.check_writable(ledger_path)
    removed = purge(data, known, guess=guess, ledger_key=ledger_key)
    # 記録があるのに1件も外せないのは、導入後に利用者が差し替えたか、台帳が
    # 古くなった状態である。成功扱いにして台帳を消すと次回は取り外せない。
    if not removed:
        sys.stderr.write("  警告: 台帳に記録されたフックを外せないため設定を変更していない。\n")
        return 2
    save_if_changed(path, data, original)
    if ledger_path and known is not None:
        led = ledger.load(ledger_path)
        if ledger_key in led:
            del led[ledger_key]
            try:
                ledger.save(ledger_path, led)
            except OSError:
                # Claude側の既定キーは、uninstall.sh が処理後に台帳自体を
                # 取り除ける旧環境の互換性を保つ。Codex側は上の
                # check_writable で変更前に拒否する。
                if ledger_key != "hooks":
                    raise
    print("  フックの登録を %d 件外した" % removed)
    return 0


def cmd_validate(path):
    """既存設定を読み、構造が妥当であることだけを確認する。"""
    load(path)
    return 0


def cmd_validate_codex(path, ledger_path):
    """Codex台帳と現在のhooks.jsonがstrict managed構造で一致するか確認する。"""
    data, _ = load(path)
    known = recorded_hooks(ledger_path, "codex_hooks")
    return 0 if codex_managed_positions(data, known) is not None else 1


def cmd_same(path, other):
    """2つの設定ファイルがデータとして同値なら 0 を返す。

    uninstall.sh が「控えと原状が同じか」を判断するために使う。書式の違いで
    残す判断をすると、控えが永久に片付かない。
    """
    def read(p):
        if not os.path.exists(p):
            return {}
        try:
            with open(p, encoding="utf-8-sig", errors="surrogateescape", newline="") as f:
                text = f.read().strip()
            return json.loads(text.lstrip("\ufeff")) if text else {}
        except (OSError, ValueError):
            return None

    a, b = read(path), read(other)
    return 0 if a is not None and a == b else 1


def main(argv):
    if len(argv) == 4 and argv[1] == "same":
        return cmd_same(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "validate":
        return cmd_validate(argv[2])
    if len(argv) == 5 and argv[1] == "validate-codex" and argv[3] == "--ledger":
        return cmd_validate_codex(argv[2], argv[4])
    if len(argv) < 3 or argv[1] not in ("install", "remove"):
        sys.stderr.write(
            "usage: settings-hooks.py {install|remove} <path> "
            "[--ledger <ledger>] [--ledger-key hooks|codex_hooks] "
            "[--matcher EVENT=REGEX] "
            "[--additional-context-limit EVENT=POSITIVE_INTEGER] "
            "[--guess] [event:command ...]\n"
            "       settings-hooks.py validate-codex <path> --ledger <ledger>\n"
        )
        return 64

    rest = argv[3:]
    ledger_path = ""
    ledger_key = "hooks"
    ledger_key_seen = False
    guess = False
    matchers = {}
    additional_limits = {}
    specs = []
    i = 0
    while i < len(rest):
        token = rest[i]
        if token == "--ledger":
            if ledger_path or i + 1 >= len(rest):
                sys.stderr.write("--ledger には台帳のパスが要る\n")
                return 64
            ledger_path = rest[i + 1]
            i += 2
            continue
        if token == "--ledger-key":
            if (
                ledger_key_seen
                or i + 1 >= len(rest)
                or rest[i + 1] not in LEDGER_KEYS
            ):
                sys.stderr.write("--ledger-key は hooks または codex_hooks を1回だけ指定する\n")
                return 64
            ledger_key = rest[i + 1]
            ledger_key_seen = True
            i += 2
            continue
        if token == "--guess":
            if argv[1] != "remove" or guess:
                sys.stderr.write("--guess は remove で1回だけ指定できる\n")
                return 64
            guess = True
            i += 1
            continue
        if token == "--matcher":
            if argv[1] != "install" or i + 1 >= len(rest):
                sys.stderr.write("--matcher は install で EVENT=REGEX を指定する\n")
                return 64
            event, separator, matcher = rest[i + 1].partition("=")
            if not separator or not event or not matcher or event in matchers:
                sys.stderr.write("matcher の指定が妥当でない: %r\n" % rest[i + 1])
                return 64
            matchers[event] = matcher
            i += 2
            continue
        if token == "--additional-context-limit":
            if argv[1] != "install" or i + 1 >= len(rest):
                sys.stderr.write("--additional-context-limit は install で EVENT=POSITIVE_INTEGER を指定する\n")
                return 64
            event, separator, value = rest[i + 1].partition("=")
            if (
                not separator
                or not event
                or event in additional_limits
                or not re.match(r"^[1-9][0-9]*$", value)
            ):
                sys.stderr.write("追加コンテキスト上限は正の10進整数で指定する: %r\n" % rest[i + 1])
                return 64
            additional_limits[event] = int(value)
            i += 2
            continue
        if token.startswith("-"):
            sys.stderr.write("不明なオプションまたは引数: %s\n" % token)
            return 64
        specs.append(token)
        i += 1

    if argv[1] == "install":
        return cmd_install(argv[2], ledger_path, ledger_key, specs, matchers, additional_limits)
    if specs:
        sys.stderr.write("remove にフック指定は渡せない\n")
        return 64
    return cmd_remove(argv[2], ledger_path, ledger_key, guess)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except OSError as e:
        # 書き込めない・読めない環境で python のトレースバックを生で見せない。
        # 利用者にとっては「何が起きたか」だけが要る情報である。
        sys.stderr.write("ファイルを操作できない (%s)\n" % e)
        sys.exit(1)
