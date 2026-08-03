#!/usr/bin/env python3
"""Claude Code transcript token usage reporter.

This script is intentionally read-only. It aggregates transcript metadata into a
Markdown report without copying prompt text, message bodies, command arguments,
environment variables, or other secret-bearing content into the output.
"""

import argparse
import hashlib
import html
import json
import os
import re
import sys
import tempfile
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone


HOME = os.path.expanduser("~")
CLAUDE_DIR = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
PROJECTS_DIR = os.path.join(CLAUDE_DIR, "projects")

MODEL_SAFE_RE = re.compile(r"^[A-Za-z0-9._\[\]()<>-]+$")
MARKDOWN_LINK_RE = re.compile(r"(!?)\[([^\]\r\n]*)\]\(([^)\r\n]*)\)")
CREDENTIAL_RE = re.compile(
    r"(?:^(?:sk|ghp|github_pat|xox[baprs])[-_]"
    r"|^bearer[ ]+"
    r"|(?:api[_-]?key|token|secret|password|credential|authorization)[ ]*[:=]"
    r"|(?:^|[^A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?=$|[^A-Za-z0-9])"
    r"|(?:^|[^A-Za-z0-9])AIza[A-Za-z0-9_-]{20,}(?=$|[^A-Za-z0-9])"
    r"|(?:^|[^A-Za-z0-9])glpat-[A-Za-z0-9_-]{20,}(?=$|[^A-Za-z0-9]))",
    re.IGNORECASE,
)
FALLBACK_WARNING = (
    "警告: 現在のリポジトリに対応する記録を特定できないため、"
    "利用可能な全プロジェクトを集計した。"
)
CALIBRATION_DEFAULTS = {
    "min_sessions": 5,
    "min_assistant_turns": 100,
}
CALIBRATION_MAX = 1000000
DEFAULT_SESSION_CUT = 30000000
CALIBRATION_SOURCE = "メインセッションの重複排除後 cache_read 中央値"
TOKEN_SAVER_DIRNAME = ".token" + "-saver"


def fmt(value):
    return f"{value:,}"


def read_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def read_token_saver_config(config_path):
    if os.path.islink(config_path) or os.path.islink(os.path.dirname(config_path)):
        return None
    data = read_json(config_path)
    return data if isinstance(data, dict) else None


def calibration_positive_int(value, default):
    if (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 1 <= value <= CALIBRATION_MAX
    ):
        return value
    return default


def load_calibration_settings(config_path):
    settings = dict(CALIBRATION_DEFAULTS)
    data = read_token_saver_config(config_path)
    if not data:
        return settings
    calibration = data.get("calibration")
    if not isinstance(calibration, dict):
        return settings
    for key, default in CALIBRATION_DEFAULTS.items():
        settings[key] = calibration_positive_int(calibration.get(key), default)
    return settings


def load_session_cut_settings(config_path):
    data = read_token_saver_config(config_path)
    values = {
        "initial_cache_read": DEFAULT_SESSION_CUT,
        "increment_cache_read": DEFAULT_SESSION_CUT,
    }
    if not data:
        return values
    session_cut = data.get("suggest_session_cut")
    if not isinstance(session_cut, dict):
        return values
    for key, default in values.items():
        value = session_cut.get(key)
        if isinstance(value, int) and not isinstance(value, bool) and value > 0:
            values[key] = value
        else:
            values[key] = default
    return values


def calibration_fingerprint(args, since, settings, main_paths, sub_paths):
    digest = hashlib.sha256()
    period = "all" if since is None else "days:{}".format(args.days)
    for value in (
        period,
        "min_sessions:{}".format(settings["min_sessions"]),
        "min_assistant_turns:{}".format(settings["min_assistant_turns"]),
    ):
        digest.update(value.encode("utf-8"))
        digest.update(b"\0")
    for path in sorted(main_paths + sub_paths):
        try:
            metadata = os.stat(path)
        except OSError:
            continue
        digest.update(path.encode("utf-8", "surrogateescape"))
        digest.update(b"\0")
        digest.update(str(metadata.st_size).encode("ascii"))
        digest.update(b"\0")
        digest.update(str(int(metadata.st_mtime * 1000000000)).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest()


def build_calibration(scan, args, since, main_paths, sub_paths):
    config_path = project_path(".claude", "token-saver.json")
    settings = load_calibration_settings(config_path)
    current = load_session_cut_settings(config_path)
    values = [stats.cache_read for stats in scan.session_stats.values()]
    baseline = median_integer(values)
    session_count = len(scan.session_stats)
    assistant_turns = sum(stats.assistant_turns for stats in scan.session_stats.values())
    eligible = (
        session_count >= settings["min_sessions"]
        and assistant_turns >= settings["min_assistant_turns"]
        and baseline is not None
        and baseline > 0
    )
    period = "全期間" if since is None else "直近 {} 日".format(args.days)
    return {
        "eligible": eligible,
        "period": period,
        "min_sessions": settings["min_sessions"],
        "min_assistant_turns": settings["min_assistant_turns"],
        "session_count": session_count,
        "assistant_turns": assistant_turns,
        "baseline_cache_read": baseline,
        "current_initial": current["initial_cache_read"],
        "current_increment": current["increment_cache_read"],
        "recommended_levels": [baseline, baseline * 2, baseline * 3] if eligible else [],
        "fingerprint": calibration_fingerprint(
            args, since, settings, main_paths, sub_paths
        ),
        "source": CALIBRATION_SOURCE,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def write_calibration_snapshot(snapshot):
    state_root = project_path(TOKEN_SAVER_DIRNAME)
    calibration_dir = os.path.join(state_root, "calibration")
    for directory in (state_root, calibration_dir):
        if os.path.lexists(directory):
            if os.path.islink(directory) or not os.path.isdir(directory):
                return False
        else:
            try:
                os.mkdir(directory)
            except OSError:
                return False

    target = os.path.join(calibration_dir, "latest.json")
    if os.path.lexists(target) and os.path.islink(target):
        return False
    temp_path = None
    try:
        descriptor, temp_path = tempfile.mkstemp(
            prefix=".latest.", suffix=".tmp", dir=calibration_dir
        )
        if os.path.islink(temp_path):
            return False
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, target)
        temp_path = None
        return True
    except (OSError, TypeError, ValueError):
        return False
    finally:
        if temp_path:
            try:
                os.unlink(temp_path)
            except OSError:
                pass


def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def _utf16_units(text):
    encoded = text.encode("utf-16-le", "surrogatepass")
    return [
        encoded[index:index + 2].decode("utf-16-le", "surrogatepass")
        for index in range(0, len(encoded), 2)
    ]


def _js_string_hash(units):
    total = 0
    for unit in units:
        total = (total * 31 + ord(unit)) & 0xFFFFFFFF
    if total >= 0x80000000:
        total -= 0x100000000
    return total


def _to_base36(value):
    if value == 0:
        return "0"
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = []
    while value:
        value, rem = divmod(value, 36)
        out.append(digits[rem])
    return "".join(reversed(out))


def project_key(path):
    units = _utf16_units(path)
    sanitized = "".join(
        unit if unit.isascii() and unit.isalnum() else "-"
        for unit in units
    )
    if len(sanitized) <= 200:
        return sanitized
    return f"{sanitized[:200]}-{_to_base36(abs(_js_string_hash(units)))}"


def find_project_root(start="."):
    current = os.path.abspath(start)
    while True:
        if os.path.exists(os.path.join(current, ".git")) or os.path.isdir(
            os.path.join(current, ".claude")
        ):
            return current
        parent = os.path.dirname(current)
        if parent == current:
            return os.path.abspath(start)
        current = parent


PROJECT_ROOT = find_project_root()


def project_path(*parts):
    return os.path.join(PROJECT_ROOT, *parts)


def is_token_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def safe_int(value):
    if not is_token_count(value):
        return 0
    return value


def median_integer(values):
    ordered = sorted(value for value in values if isinstance(value, int) and value > 0)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2


def has_unsafe_text(text):
    return any(
        ord(ch) == 127 or unicodedata.category(ch) in ("Cc", "Cf", "Cs")
        for ch in text
    )


def credential_shaped(text):
    return CREDENTIAL_RE.search(text) is not None


def path_shaped_metadata(text):
    return (
        text in (".", "..", "~")
        or text.startswith(("./", "../", "~/"))
        or os.path.isabs(text)
        or re.match(r"^[A-Za-z]:[\\/]", text) is not None
        or "://" in text
    )


def sanitize_name(name):
    if not isinstance(name, str) or not name:
        return None
    name = name.strip()
    if not name or len(name) > 200:
        return None
    if (
        any(ch in name for ch in "\"'{}[]\\`|/")
        or has_unsafe_text(name)
        or credential_shaped(name)
        or path_shaped_metadata(name)
    ):
        return None
    return name


def sanitize_model(name):
    if not isinstance(name, str) or not name:
        return None
    name = name.strip()
    if credential_shaped(name) or has_unsafe_text(name) or path_shaped_metadata(name):
        return None
    return name if MODEL_SAFE_RE.match(name) else None


def dedup_scalar(value):
    if isinstance(value, str) and value:
        return ("str", value)
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return ("int", value)
    return None


def fallback_message_key(entry, usage):
    request_id = dedup_scalar(entry.get("requestId"))
    timestamp = entry.get("timestamp")
    if not isinstance(timestamp, str):
        timestamp = None
    return (
        "fallback",
        request_id,
        timestamp,
        safe_int(usage.get("input_tokens")),
        safe_int(usage.get("cache_creation_input_tokens")),
        safe_int(usage.get("cache_read_input_tokens")),
        safe_int(usage.get("output_tokens")),
    )


def content_blocks(message):
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    return content if isinstance(content, list) else []


class Usage:
    FIELDS = (
        ("input", "input_tokens"),
        ("cache_creation", "cache_creation_input_tokens"),
        ("cache_read", "cache_read_input_tokens"),
        ("output", "output_tokens"),
    )

    def __init__(self):
        self.input = 0
        self.cache_creation = 0
        self.cache_read = 0
        self.output = 0

    def add_raw(self, usage):
        self.input += safe_int(usage.get("input_tokens"))
        self.cache_creation += safe_int(usage.get("cache_creation_input_tokens"))
        self.cache_read += safe_int(usage.get("cache_read_input_tokens"))
        self.output += safe_int(usage.get("output_tokens"))

    def __iadd__(self, other):
        self.input += other.input
        self.cache_creation += other.cache_creation
        self.cache_read += other.cache_read
        self.output += other.output
        return self

    @property
    def total(self):
        return self.input + self.cache_creation + self.cache_read + self.output

    def row(self):
        return [
            fmt(self.input),
            fmt(self.cache_creation),
            fmt(self.cache_read),
            fmt(self.output),
            fmt(self.total),
        ]


class SessionStats:
    def __init__(self):
        self.cache_read = 0
        self.assistant_turns = 0


class Scan:
    def __init__(self):
        self.files = 0
        self.lines = 0
        self.sessions = set()
        self.session_stats = {}
        self.main = Usage()
        self.by_model = defaultdict(Usage)
        self.tool_calls = Counter()
        self.read_paths = Counter()
        self.read_ext = Counter()
        self.agent_calls = Counter()
        self.agent_results = Counter()
        self.agent_tokens = defaultdict(int)
        self.agent_models = defaultdict(Counter)
        self.agent_usage = defaultdict(Usage)
        self.agent_usage_total = Usage()
        self.agent_max = defaultdict(int)
        self.agent_total = 0
        self.sub_files = 0
        self.sub_mcp_calls = Counter()
        self.scanned_dirs = []
        self.fell_back = False
        self.skipped_dupes = 0
        self.skipped_fallback_dupes = 0
        self.messages = 0
        self.no_message_id = 0
        self.no_timestamp = 0
        self.no_timestamp_with_usage = 0


def scan_transcripts(paths, since):
    scan = Scan()
    seen_messages = set()
    for path in paths:
        scan.files += 1
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                scan.lines += 1
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue

                stamp = parse_ts(entry.get("timestamp"))
                if since is not None:
                    if stamp is None:
                        scan.no_timestamp += 1
                        message_probe = entry.get("message")
                        if (
                            entry.get("type") == "assistant"
                            and isinstance(message_probe, dict)
                            and isinstance(message_probe.get("usage"), dict)
                        ):
                            scan.no_timestamp_with_usage += 1
                        continue
                    if stamp < since:
                        continue

                session_id = entry.get("sessionId")
                session_key = str(session_id) if session_id else None
                if session_key:
                    scan.sessions.add(session_key)

                message = entry.get("message")
                if entry.get("type") == "assistant" and isinstance(message, dict):
                    usage = message.get("usage")
                    if isinstance(usage, dict):
                        message_id = dedup_scalar(message.get("id"))
                        if message_id is None:
                            scan.no_message_id += 1
                            key = fallback_message_key(entry, usage)
                        else:
                            key = ("id", message_id)
                        if key in seen_messages:
                            if message_id is not None:
                                scan.skipped_dupes += 1
                            else:
                                scan.skipped_fallback_dupes += 1
                        else:
                            seen_messages.add(key)
                            one = Usage()
                            one.add_raw(usage)
                            scan.main += one
                            scan.messages += 1
                            if session_key:
                                stats = scan.session_stats.setdefault(
                                    session_key, SessionStats()
                                )
                                stats.cache_read += one.cache_read
                                stats.assistant_turns += 1
                            model = sanitize_model(message.get("model")) or "(不明)"
                            scan.by_model[model] += one

                    for block in content_blocks(message):
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        name = str(block.get("name") or "(不明)")
                        scan.tool_calls[name] += 1
                        tool_input = block.get("input")
                        if not isinstance(tool_input, dict):
                            continue
                        if name == "Agent":
                            subagent = (
                                sanitize_name(tool_input.get("subagent_type")) or "(既定)"
                            )
                            scan.agent_calls[subagent] += 1
                        elif name in ("Read", "NotebookRead"):
                            target = tool_input.get("file_path") or tool_input.get(
                                "notebook_path"
                            )
                            if isinstance(target, str) and target:
                                scan.read_paths[target] += 1
                                ext = os.path.splitext(target)[1].lower() or "(拡張子なし)"
                                scan.read_ext[ext] += 1

                result = entry.get("toolUseResult")
                if (
                    isinstance(result, dict)
                    and is_token_count(result.get("totalTokens"))
                    and result.get("agentType")
                ):
                    tokens = result["totalTokens"]
                    subagent = sanitize_name(result.get("agentType")) or "(不明)"
                    scan.agent_total += tokens
                    scan.agent_tokens[subagent] += tokens
                    scan.agent_results[subagent] += 1
                    scan.agent_max[subagent] = max(scan.agent_max[subagent], tokens)
                    model = sanitize_model(result.get("resolvedModel")) or "(不明)"
                    scan.agent_models[subagent][model] += 1
                    usage = result.get("usage")
                    if isinstance(usage, dict):
                        one = Usage()
                        one.add_raw(usage)
                        scan.agent_usage[subagent] += one
                        scan.agent_usage_total += one
    return scan


def disabled_plugins():
    disabled = set()
    for settings_path in (
        os.path.join(CLAUDE_DIR, "settings.json"),
        project_path(".claude", "settings.json"),
        project_path(".claude", "settings.local.json"),
    ):
        data = read_json(settings_path)
        if not isinstance(data, dict):
            continue
        enabled = data.get("enabledPlugins")
        if not isinstance(enabled, dict):
            continue
        for key, value in enabled.items():
            if value is False and isinstance(key, str):
                name = sanitize_name(key.split("@")[0])
                if name:
                    disabled.add(name)
    return disabled


def newest_entries(entries):
    best = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            continue
        scope = entry.get("scope") if isinstance(entry.get("scope"), str) else ""
        stamp = entry.get("lastUpdated") or entry.get("installedAt") or ""
        key = (str(stamp) if isinstance(stamp, str) else "", index)
        if scope not in best or key > best[scope][0]:
            best[scope] = (key, entry)
    return [entry for _key, entry in best.values()]


def within(root, path):
    try:
        root_real = os.path.realpath(root)
        path_real = os.path.realpath(path)
    except OSError:
        return False
    return path_real == root_real or path_real.startswith(root_real + os.sep)


def read_mcp_server_names(plugin_root):
    names = []
    sources = [os.path.join(plugin_root, ".mcp.json")]
    manifest = read_json(os.path.join(plugin_root, ".claude-plugin", "plugin.json"))
    if isinstance(manifest, dict):
        declared = manifest.get("mcpServers")
        if isinstance(declared, dict):
            names.extend(declared)
        else:
            refs = [declared] if isinstance(declared, str) else declared
            if not isinstance(refs, list):
                refs = []
            for item in refs:
                if not isinstance(item, str) or not item:
                    continue
                target = os.path.join(plugin_root, item)
                if within(plugin_root, target):
                    sources.append(target)
    for source in sources:
        data = read_json(source)
        if not isinstance(data, dict):
            continue
        servers = data.get("mcpServers")
        if isinstance(servers, dict):
            names.extend(servers)
    out = []
    for key in names:
        name = sanitize_name(key) if isinstance(key, str) else None
        if name:
            out.append(name)
    return out


def plugin_mcp_servers():
    installed = read_json(os.path.join(CLAUDE_DIR, "plugins", "installed_plugins.json"))
    if not isinstance(installed, dict):
        return []
    plugins = installed.get("plugins")
    if not isinstance(plugins, dict):
        return []
    disabled = disabled_plugins()
    rows = []
    for full_name, entries in plugins.items():
        if not isinstance(full_name, str) or not isinstance(entries, list):
            continue
        plugin_name = sanitize_name(full_name.split("@")[0])
        if not plugin_name or plugin_name in disabled:
            continue
        for entry in newest_entries(entries):
            root = entry.get("installPath")
            if not isinstance(root, str) or not os.path.isabs(root):
                continue
            for name in read_mcp_server_names(root):
                rows.append((f"plugin:{plugin_name}", name))
    return rows


def config_json_candidates():
    candidates = [os.path.join(CLAUDE_DIR, "claude.json"), os.path.join(HOME, ".claude.json")]
    out = []
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out


def mcp_summary():
    rows = []
    for config_path in config_json_candidates():
        data = read_json(config_path)
        if not isinstance(data, dict):
            continue
        servers = data.get("mcpServers")
        if isinstance(servers, dict):
            for key in servers:
                name = sanitize_name(key)
                if name:
                    rows.append(("user", name))
    project_mcp = read_json(project_path(".mcp.json"))
    if isinstance(project_mcp, dict) and isinstance(project_mcp.get("mcpServers"), dict):
        for key in project_mcp["mcpServers"]:
            name = sanitize_name(key)
            if name:
                rows.append(("project", name))
    rows.extend(plugin_mcp_servers())
    unique = []
    seen = set()
    for scope, name in rows:
        item = (scope, name)
        if item in seen:
            continue
        seen.add(item)
        unique.append(item)
    return unique


def mcp_tool_prefixes(tool_calls):
    found = Counter()
    for name, count in tool_calls.items():
        if not isinstance(name, str) or not name.startswith("mcp__"):
            continue
        rest = name[len("mcp__"):]
        server, sep, _tool = rest.partition("__")
        if not sep or not server:
            continue
        safe = sanitize_name(server)
        if safe:
            found[safe] += count
    return found


def scan_mcp_tool_names(paths, since):
    found = Counter()
    for path in paths:
        try:
            handle = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with handle:
            for line in handle:
                if "mcp__" not in line:
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                if since is not None:
                    stamp = parse_ts(entry.get("timestamp"))
                    if stamp is None or stamp < since:
                        continue
                for block in content_blocks(entry.get("message")):
                    if not isinstance(block, dict) or block.get("type") != "tool_use":
                        continue
                    name = block.get("name")
                    if isinstance(name, str) and name.startswith("mcp__"):
                        found[name] += 1
    return found


def normalize_server_name(name):
    return re.sub(r"[^0-9a-z]+", "_", name.lower()).strip("_")


def mask_outside(path, roots):
    if not isinstance(path, str) or not path or not os.path.isabs(path):
        return "(repo外)"
    target = os.path.normpath(path)
    for root in roots:
        base = os.path.normpath(os.path.abspath(root))
        if target == base or target.startswith(base + os.sep):
            relative = os.path.relpath(target, base)
            if has_unsafe_text(relative) or credential_shaped(relative):
                return "(非表示)"
            return relative
    return "(repo外)"


def markdown_cell(value):
    text = str(value)
    if has_unsafe_text(text) or credential_shaped(text):
        return "(非表示)"
    text = html.escape(text, quote=False)
    text = text.replace("\\", "\\\\").replace("`", "\\`").replace("|", "\\|")

    def escape_link(match):
        image = "\\!" if match.group(1) else ""
        return (
            image
            + "\\["
            + match.group(2)
            + "\\]\\("
            + match.group(3)
            + "\\)"
        )

    return MARKDOWN_LINK_RE.sub(escape_link, text)


def table(headers, rows):
    if not rows:
        return ["（該当なし）", ""]
    out = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join(["---"] * len(headers)) + "|",
    ]
    for row in rows:
        out.append("| " + " | ".join(markdown_cell(cell) for cell in row) + " |")
    out.append("")
    return out


def top_rows(rows, limit):
    return rows[:limit]


def build_report(args, scan, project_dirs, since, calibration=None):
    lines = []
    add = lines.append
    window = f"直近 {args.days} 日" if since else "全期間"

    add("# Claude Code トークン計測レポート")
    add("")
    add("## 計測条件")
    add("")
    add(f"- 対象期間: {window}")
    add(f"- 走査したトランスクリプト: {scan.files} 本 / {fmt(scan.lines)} 行")
    add(f"- セッション数: {len(scan.sessions)}")
    add(
        "- 重複排除した行: "
        f"{fmt(scan.skipped_dupes)}（同じ `message.id` の usage は一度だけ数える）"
    )
    if scan.no_message_id:
        add(
            "- `message.id` を持たない usage 行: "
            f"{fmt(scan.no_message_id)}（`requestId` と usage の内容で代替キーを作る"
            f"。代替キーで重複排除した行: {fmt(scan.skipped_fallback_dupes)}）"
        )
    if scan.no_timestamp:
        add(
            "- timestamp が無く期間判定できず除外した行: "
            f"{fmt(scan.no_timestamp)}"
            f"（うち usage あり: {fmt(scan.no_timestamp_with_usage)}）"
        )
    if scan.scanned_dirs:
        add(f"- 走査したプロジェクト: {len(scan.scanned_dirs)} 件")
    if scan.fell_back:
        add(f"- {FALLBACK_WARNING}")
    add("")

    add("## 実測合計")
    add("")
    rows = [
        ["main", *scan.main.row()],
        [
            "subagent usage",
            *scan.agent_usage_total.row(),
        ],
    ]
    lines.extend(table(["区分", "input", "cache_creation", "cache_read", "output", "usage合計"], rows))
    add(f"- main 合計: **{fmt(scan.main.total)}**")
    add(f"- subagent `toolUseResult.totalTokens` 合計: **{fmt(scan.agent_total)}**")
    if scan.sub_files:
        add(
            f"- `<session>/subagents/` の詳細ログ {scan.sub_files} 本は別枠で扱い、"
            "親の合計へ二重計上しない。"
        )
    add("")

    add("## モデルとサブエージェント")
    add("")
    model_rows = top_rows([
        [name, *usage.row()]
        for name, usage in sorted(scan.by_model.items(), key=lambda item: -item[1].total)
    ], args.top)
    lines.extend(table(["model", "input", "cache_creation", "cache_read", "output", "usage合計"], model_rows))
    agent_rows = []
    for subagent in sorted(
        set(scan.agent_calls) | set(scan.agent_tokens),
        key=lambda item: -scan.agent_tokens.get(item, 0),
    ):
        models = ", ".join(
            f"{model} × {count}"
            for model, count in scan.agent_models.get(subagent, Counter()).most_common(3)
        ) or "-"
        agent_rows.append(
            [
                subagent,
                scan.agent_calls.get(subagent, 0),
                scan.agent_results.get(subagent, 0),
                fmt(scan.agent_tokens.get(subagent, 0)),
                models,
            ]
        )
    lines.extend(
        table(
            ["subagent_type", "起動", "結果取得", "totalTokens", "resolvedModel"],
            top_rows(agent_rows, args.top),
        )
    )

    add("## MCP")
    add("")
    servers = mcp_summary()
    if servers:
        lines.extend(table(["スコープ", "サーバ名"], top_rows(servers, args.top)))
    else:
        add("（設定から検出できた MCP サーバはなし）")
        add("")
    used = mcp_tool_prefixes(scan.tool_calls)
    if scan.sub_mcp_calls:
        used += mcp_tool_prefixes(scan.sub_mcp_calls)
    known = {
        normalize_server_name(name)
        for _scope, name in servers
        if normalize_server_name(name)
    }
    unknown = [
        (prefix, count)
        for prefix, count in used.most_common()
        if normalize_server_name(prefix) not in known
    ]
    add(f"- MCP 利用合計: {fmt(sum(used.values()))} 回")
    if used:
        lines.extend(
            table(
                ["ツール接頭辞", "回数"],
                top_rows(
                    [[prefix, fmt(count)] for prefix, count in used.most_common()],
                    args.top,
                ),
            )
        )
    if unknown:
        add("- 設定から検出できていない接頭辞:")
        for prefix, count in top_rows(unknown, args.top):
            add(f"  - {markdown_cell(prefix)}: {fmt(count)} 回")
    add("")

    if args.paths:
        add("## Read パス")
        add("")
        masked = Counter()
        for path, count in scan.read_paths.items():
            masked[mask_outside(path, project_dirs)] += count
        lines.extend(
            table(
                ["ファイル", "Read 回数"],
                [[path, fmt(count)] for path, count in masked.most_common(args.top)],
            )
        )

    if calibration is not None:
        add("## キャリブレーション")
        add("")
        add("- 対象期間: {}".format(calibration["period"]))
        add(
            "- 判定条件: セッション {} 件以上 / assistant ターン {} 件以上".format(
                calibration["min_sessions"], calibration["min_assistant_turns"]
            )
        )
        add(
            "- 観測値: セッション {} 件 / assistant ターン {} 件".format(
                calibration["session_count"], calibration["assistant_turns"]
            )
        )
        if calibration["eligible"]:
            baseline, level_two, level_three = calibration["recommended_levels"]
            add("- 判定: **算出可能**")
            add("- 算出日: {}".format(calibration["generated_at"]))
            add("- 算出元: {}".format(calibration["source"]))
            add("- 推奨段階1単位: **{}** cache_read".format(fmt(baseline)))
            add("- 推奨段階2: {} cache_read".format(fmt(level_two)))
            add("- 推奨段階3: {} cache_read".format(fmt(level_three)))
            add(
                "- 現在値: initial {} / increment {} cache_read".format(
                    fmt(calibration["current_initial"]),
                    fmt(calibration["current_increment"]),
                )
            )
        else:
            add("- 判定: **サンプル不足**")
            if calibration["session_count"] < calibration["min_sessions"]:
                add(
                    "- 不足: セッション数 {} 件（必要 {} 件）".format(
                        calibration["session_count"], calibration["min_sessions"]
                    )
                )
            if calibration["assistant_turns"] < calibration["min_assistant_turns"]:
                add(
                    "- 不足: assistant ターン {} 件（必要 {} 件）".format(
                        calibration["assistant_turns"], calibration["min_assistant_turns"]
                    )
                )
            if calibration["baseline_cache_read"] is None:
                add("- 有効な正の cache_read サンプルがないため、推奨値は算出しない。")
        add("")

    add("## 共有時の境界")
    add("")
    add("- 含める: 集計値、モデル名、subagent_type、MCP サーバ名、repo 内の相対パス。")
    add("- 含めない: prompt、content、本文、環境変数、認証情報、repo 外の実パス。")
    add("- repo 外や相対指定の Read パスは `(repo外)` に置換する。")
    add("- 入力の transcript・設定・repository は読み取り専用で扱う。")
    add("")

    return "\n".join(lines)


def select_project_dirs(args):
    if not os.path.isdir(PROJECTS_DIR):
        return [], False
    all_names = [
        name
        for name in sorted(os.listdir(PROJECTS_DIR))
        if os.path.isdir(os.path.join(PROJECTS_DIR, name))
    ]
    if args.all_projects:
        return [os.path.join(PROJECTS_DIR, name) for name in all_names], False

    project_root = os.path.abspath(PROJECT_ROOT)
    candidates = {
        project_root.replace("/", "-").replace("_", "-"),
        project_root.replace("/", "-"),
        project_key(project_root),
        project_key(os.path.realpath(project_root)),
    }
    targets = [
        os.path.join(PROJECTS_DIR, name) for name in all_names if name in candidates
    ]
    if targets:
        return targets, False
    return [os.path.join(PROJECTS_DIR, name) for name in all_names], True


def transcript_paths(project_dirs):
    main_paths = []
    sub_paths = []
    for directory in project_dirs:
        for base, _dirs, files in os.walk(directory):
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                full = os.path.join(base, name)
                if os.path.dirname(full) == directory:
                    main_paths.append(full)
                else:
                    sub_paths.append(full)
    return main_paths, sub_paths


def main():
    parser = argparse.ArgumentParser(
        description="Claude Code のトークン消費量を計測して Markdown で報告する"
    )
    parser.add_argument("--days", type=int, default=7, help="対象期間（日）。0 で全期間。既定 7")
    parser.add_argument("--out", help="Markdown を書き出すファイル")
    parser.add_argument("--top", type=int, default=15, help="各一覧の最大行数。既定 15")
    parser.add_argument(
        "--all-projects",
        action="store_true",
        help="全プロジェクトを対象にする（既定は cwd の project key のみ）",
    )
    parser.add_argument("--paths", action="store_true", help="Read パスの要約も出す")
    parser.add_argument(
        "--calibrate", action="store_true", help="読み取り専用でキャリブレーションを算出する"
    )
    args = parser.parse_args()

    if args.days < 0:
        print("--days には 0 以上を指定してください（0 は全期間）", file=sys.stderr)
        return 2
    if args.top <= 0:
        print("--top には 1 以上を指定してください", file=sys.stderr)
        return 2
    if not os.path.isdir(PROJECTS_DIR):
        print(f"トランスクリプトが見つかりません: {PROJECTS_DIR}", file=sys.stderr)
        return 1

    project_dirs, fell_back = select_project_dirs(args)
    main_paths, sub_paths = transcript_paths(project_dirs)
    since = None if args.days == 0 else datetime.now(timezone.utc) - timedelta(days=args.days)

    scan = scan_transcripts(main_paths, since)
    scan.sub_files = len(sub_paths)
    scan.sub_mcp_calls = scan_mcp_tool_names(sub_paths, since)
    scan.scanned_dirs = [os.path.basename(path) for path in project_dirs]
    scan.fell_back = fell_back
    if fell_back:
        print(FALLBACK_WARNING, file=sys.stderr)
    calibration = None
    if args.calibrate:
        calibration = build_calibration(scan, args, since, main_paths, sub_paths)
        if not write_calibration_snapshot(calibration):
            print("キャリブレーション snapshot の保存に失敗しました", file=sys.stderr)
            return 1
    report = build_report(args, scan, [PROJECT_ROOT], since, calibration)

    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(report)
                handle.write("\n")
        except OSError as exc:
            print(f"書き出しに失敗しました: {exc}", file=sys.stderr)
            return 1
        print(f"書き出しました: {args.out}")
    else:
        print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
