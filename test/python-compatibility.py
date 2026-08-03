#!/usr/bin/env python3
"""lib/*.py のPython 3.6互換性と主要なCLI境界を検査する。"""

import json
import os
import subprocess
import sys
import tempfile


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(REPO_ROOT, "lib")
ENGINE_PATH = os.path.join(REPO_ROOT, "scripts", "measure-token-usage.py")


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


def bytecode_paths(root):
    paths = set()
    for base, _dirs, files in os.walk(root):
        for name in files:
            if name.endswith(".pyc"):
                paths.add(os.path.relpath(os.path.join(base, name), root))
    return paths


def assert_no_new_bytecode(root, before):
    created = sorted(bytecode_paths(root) - before)
    check(not created, "libに新規pycが作られた: %s" % ", ".join(created))


def check_lib_syntax():
    names = []
    for name in os.listdir(LIB_DIR):
        path = os.path.join(LIB_DIR, name)
        if name.endswith(".py") and os.path.isfile(path):
            names.append(name)
    names.sort()
    check(names, "lib/*.py が1本も無い")
    for name in names:
        path = os.path.join(LIB_DIR, name)
        with open(path, encoding="utf-8") as stream:
            source = stream.read()
        compile(source, path, "exec")
    return len(names)


def check_engine_syntax():
    with open(ENGINE_PATH, encoding="utf-8") as stream:
        source = stream.read()
    compile(source, ENGINE_PATH, "exec")
    forbidden = (".fromisoformat(", ".isascii(")
    for marker in forbidden:
        check(marker not in source, "Python 3.6非対応APIがengineに残っている: %s" % marker)


def check_calibration_cli(temp_root):
    fixture_root = os.path.join(temp_root, "calibration-cli-repo")
    config_root = os.path.join(temp_root, "calibration-cli-config")
    project_dir = os.path.join(config_root, "projects", "fixture-project")
    os.makedirs(os.path.join(fixture_root, ".git"))
    os.makedirs(os.path.join(fixture_root, ".claude"))
    os.makedirs(project_dir)

    config_path = os.path.join(fixture_root, ".claude", "token-saver.json")
    with open(config_path, "w", encoding="utf-8") as stream:
        json.dump(
            {
                "calibration": {"min_sessions": 1, "min_assistant_turns": 1},
                "suggest_session_cut": {
                    "initial_cache_read": 30000000,
                    "increment_cache_read": 30000000,
                },
                "unrelated": "CLI_CONFIG_SECRET",
            },
            stream,
        )
    config_before = open(config_path, "rb").read()

    transcript_path = os.path.join(project_dir, "session.jsonl")
    rows = [
        {
            "type": "user",
            "sessionId": "cli-session",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": "CLI_PROMPT_SECRET"}],
            },
        },
        {
            "type": "assistant",
            "sessionId": "cli-session",
            "message": {
                "id": "cli-assistant",
                "model": "claude-sonnet-5",
                "usage": {
                    "input_tokens": 1,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 10,
                    "output_tokens": 1,
                },
                "content": [
                    {
                        "type": "tool_use",
                        "name": "Bash",
                        "input": {"command": "/outside/CLI_EXTERNAL_PATH_SECRET"},
                    }
                ],
            },
        },
        {
            "type": "user",
            "sessionId": "cli-session",
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "cli-assistant-tool",
                        "content": "CLI_TOOL_RESULT_SECRET " + ("x" * 5000),
                    }
                ],
            },
        },
    ]
    with open(transcript_path, "w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(json.dumps(row) + "\n")

    report_path = os.path.join(fixture_root, "report.md")
    environment = os.environ.copy()
    environment["CLAUDE_CONFIG_DIR"] = config_root
    environment["CLI_ENV_SECRET"] = "CLI_ENV_SECRET"
    result = subprocess.run(
        [
            sys.executable,
            "-B",
            ENGINE_PATH,
            "--calibrate",
            "--days",
            "0",
            "--out",
            "report.md",
        ],
        cwd=fixture_root,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    check(result.returncode == 0, "キャリブレーションCLIが失敗した: %s" % result.stderr)
    check(os.path.isfile(report_path), "キャリブレーションCLIのreportが無い")
    check(
        os.path.isfile(os.path.join(fixture_root, ".token-saver", "calibration", "latest.json")),
        "キャリブレーションCLIのsnapshotが無い",
    )
    report = open(report_path, encoding="utf-8").read()
    for secret in (
        "CLI_CONFIG_SECRET",
        "CLI_PROMPT_SECRET",
        "CLI_TOOL_RESULT_SECRET",
        "CLI_EXTERNAL_PATH_SECRET",
        "CLI_ENV_SECRET",
    ):
        check(secret not in report, "CLI出力へ秘密値が漏えいした: %s" % secret)
    check(open(config_path, "rb").read() == config_before, "CLIが設定を変更した")
    assert_no_bytecode(temp_root)
    print("Python互換性キャリブレーションCLI: PASS")


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
    lib_bytecode_before = bytecode_paths(LIB_DIR)
    lib_count = check_lib_syntax()
    check_engine_syntax()
    with tempfile.TemporaryDirectory() as temp_root:
        check_calibration_cli(temp_root)
        check_ledger(temp_root)
        check_settings_hooks(temp_root)
        check_gitignore(temp_root)
        assert_no_bytecode(temp_root)
    # settings-hooks.py と gitignore-block.py は ledger.py を import する。
    # 実行前からあるbytecodeは利用者の状態であり、実行中に新規作成したものだけ拒否する。
    assert_no_new_bytecode(LIB_DIR, lib_bytecode_before)
    print("Python互換性スモーク: engineとlib %d本のcompile、CLI 3系統を検証" % lib_count)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (AssertionError, OSError, ValueError) as error:
        sys.stderr.write("Python互換性スモーク失敗: %s\n" % error)
        sys.exit(1)
