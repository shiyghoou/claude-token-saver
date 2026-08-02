#!/usr/bin/env python3
"""lib/*.py のPython 3.6互換性と主要なCLI境界を検査する。"""

import json
import os
import subprocess
import sys
import tempfile


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(REPO_ROOT, "lib")


def fail(message):
    raise AssertionError(message)


def check(condition, message):
    if not condition:
        fail(message)


def run_command(args, input_text=None):
    """Python 3.6に存在する引数だけで外部CLIを実行する。"""
    result = subprocess.run(
        args,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    if result.returncode != 0:
        fail(
            "コマンド失敗 rc=%d: %s\nstdout=%s\nstderr=%s"
            % (result.returncode, " ".join(args), result.stdout, result.stderr)
        )
    return result


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def assert_no_bytecode(root):
    for base, dirs, files in os.walk(root):
        check("__pycache__" not in dirs, "一時領域に__pycache__が作られた: %s" % base)
        for name in files:
            check(not name.endswith(".pyc"), "一時領域にpycが作られた: %s" % name)


def check_lib_syntax():
    for name in ("ledger.py", "settings-hooks.py", "gitignore-block.py"):
        path = os.path.join(LIB_DIR, name)
        with open(path, encoding="utf-8") as stream:
            source = stream.read()
        compile(source, path, "exec")


def check_ledger(temp_root):
    ledger = os.path.join(temp_root, "installed.json")
    script = os.path.join(LIB_DIR, "ledger.py")

    run_command([sys.executable, script, "add-skill", ledger, "sample", "/src/sample", "link"])
    skill = run_command([sys.executable, script, "get-skill", ledger, "sample"])
    check(skill.stdout.strip() == "/src/sample\x1flink", "skillの読み出し結果が不正")
    run_command([sys.executable, script, "set-value", ledger, "token_report_source", "/src/report"])
    value = run_command([sys.executable, script, "get-value", ledger, "token_report_source"])
    check(value.stdout.strip() == "/src/report", "valueの読み出し結果が不正")
    run_command([sys.executable, script, "set-flag", ledger, "gitignore_created", "1"])
    flag = run_command([sys.executable, script, "get-flag", ledger, "gitignore_created"])
    check(flag.stdout.strip() == "1", "flagの読み出し結果が不正")
    run_command([sys.executable, script, "has-record", ledger, "skills"])
    run_command([sys.executable, script, "has-record", ledger, "any"])
    data = read_json(ledger)
    check(data["skills"][0]["name"] == "sample", "台帳のskill記録が不正")


def check_settings_hooks(temp_root):
    settings = os.path.join(temp_root, "settings.local.json")
    ledger = os.path.join(temp_root, "hooks.json")
    script = os.path.join(LIB_DIR, "settings-hooks.py")
    with open(settings, "w", encoding="utf-8") as stream:
        json.dump(
            {"permissions": {"allow": ["Bash(ls:*)"]}, "hooks": {
                "SessionStart": [{"hooks": [{"type": "command", "command": "echo user"}]}]
            }},
            stream,
        )

    start_hook = os.path.join(temp_root, "handoff-check.sh")
    stop_hook = os.path.join(temp_root, "suggest-session-cut.sh")
    install = run_command([
        sys.executable, script, "install", settings, "--ledger", ledger,
        "--matcher", "SessionStart=startup|clear",
        "SessionStart:" + start_hook,
        "Stop:" + stop_hook,
    ])
    check("フックを登録した" in install.stdout, "matcher付きinstallの結果が不正")
    data = read_json(settings)
    session_groups = data["hooks"]["SessionStart"]
    check(
        any(group.get("matcher") == "startup|clear" for group in session_groups),
        "SessionStart matcherが記録されていない",
    )
    check(
        any(entry.get("command") == start_hook for group in session_groups for entry in group["hooks"]),
        "SessionStartコマンドが記録されていない",
    )
    ledger_data = read_json(ledger)
    check(len(ledger_data.get("hooks", [])) == 2, "フック台帳の件数が不正")
    run_command([sys.executable, script, "remove", settings, "--ledger", ledger])
    restored = read_json(settings)
    check(restored.get("permissions", {}).get("allow") == ["Bash(ls:*)"], "設定キーが失われた")
    check(
        restored.get("hooks", {}).get("SessionStart", [{}])[0]["hooks"][0]["command"] == "echo user",
        "利用者のフックが失われた",
    )
    check(
        not any(
            entry.get("command") in (start_hook, stop_hook)
            for groups in restored.get("hooks", {}).values()
            for group in groups
            for entry in group.get("hooks", [])
        ),
        "自前フックがremove後も残っている",
    )


def check_gitignore(temp_root):
    gitignore = os.path.join(temp_root, ".gitignore")
    script = os.path.join(LIB_DIR, "gitignore-block.py")
    original = "node_modules/\n"
    with open(gitignore, "w", encoding="utf-8") as stream:
        stream.write(original)
    body = ".token-saver/\n.token-saver/installed.json\n"
    run_command([sys.executable, script, "apply", gitignore], body)
    applied = open(gitignore, encoding="utf-8").read()
    check("# claude-token-saver (install.sh が追記。uninstall.sh で削除される)" in applied,
          "gitignoreの開始マーカーが無い")
    check(".token-saver/installed.json" in applied, "gitignoreの本文が無い")
    run_command([sys.executable, script, "remove", gitignore])
    with open(gitignore, encoding="utf-8") as stream:
        check(stream.read() == original, ".gitignoreが原状復帰していない")


def main():
    check_lib_syntax()
    with tempfile.TemporaryDirectory() as temp_root:
        check_ledger(temp_root)
        check_settings_hooks(temp_root)
        check_gitignore(temp_root)
        assert_no_bytecode(temp_root)
    # settings-hooks.py と gitignore-block.py は ledger.py を import する。
    # 実行先の lib/ に pycache を残さないことも、CLI を実行した後で確認する。
    assert_no_bytecode(LIB_DIR)
    print("Python互換性スモーク: lib 3本のcompileとCLI 3系統を検証")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, ValueError) as error:
        sys.stderr.write("Python互換性スモーク失敗: %s\n" % error)
        sys.exit(1)
