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
import time
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
HEAVY_TOOL_RESULT_BYTES = 4096


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
    result = {
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
        "prompt_key": calibration_prompt_key(
            session_count,
            assistant_turns,
            settings["min_sessions"],
            settings["min_assistant_turns"],
        ),
        "fingerprint": calibration_fingerprint(
            args, since, settings, main_paths, sub_paths
        ),
        "source": CALIBRATION_SOURCE,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    result["prompt_available"] = False
    if eligible:
        result["prompt_available"] = sync_calibration_state(
            PROJECT_ROOT,
            scan.session_stats,
            settings["min_sessions"],
            settings["min_assistant_turns"],
            PROJECT_ROOT,
        )
    return result


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
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+0000"
    elif len(text) >= 6 and text[-6] in ("+", "-") and text[-3] == ":":
        text = text[:-3] + text[-2:]
    formats = (
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d",
    )
    stamp = None
    for date_format in formats:
        try:
            stamp = datetime.strptime(text, date_format)
            break
        except ValueError:
            continue
    if stamp is None:
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
        unit if ord(unit) < 128 and unit.isalnum() else "-"
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


def median_non_negative_integer(values):
    ordered = sorted(value for value in values if isinstance(value, int) and value >= 0)
    if not ordered:
        return None
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) // 2


def calibration_prompt_key(session_count, assistant_turns, min_sessions, min_turns):
    return "{}-{}-{}-{}".format(
        session_count, assistant_turns, min_sessions, min_turns
    )


def _posix_cksum(value):
    """Return the numeric key emitted by POSIX cksum for UTF-8 text."""
    data = value.encode("utf-8", "surrogateescape")
    table = []
    for index in range(256):
        crc = index << 24
        for _bit in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
        table.append(crc)

    crc = 0
    for byte in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[((crc >> 24) ^ byte) & 0xFF]
    length = len(data)
    while length:
        byte = length & 0xFF
        crc = ((crc << 8) & 0xFFFFFFFF) ^ table[((crc >> 24) ^ byte) & 0xFF]
        length >>= 8
    return "{}-{}".format((~crc) & 0xFFFFFFFF, len(data))


def calibration_session_key(session_id, source_key):
    return _posix_cksum("{}\037{}".format(session_id, source_key))


def _calibration_state_paths(root):
    if not isinstance(root, str) or not os.path.isabs(root):
        return None
    absolute = os.path.abspath(root)
    current = os.path.sep
    for component in absolute.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        if os.path.islink(current):
            return None
    if not os.path.isdir(absolute) or os.path.islink(absolute):
        return None
    base = os.path.join(absolute, TOKEN_SAVER_DIRNAME)
    calibration_dir = os.path.join(base, "calibration")
    for directory in (base, calibration_dir):
        if os.path.lexists(directory):
            if os.path.islink(directory) or not os.path.isdir(directory):
                return None
        else:
            try:
                os.mkdir(directory)
            except OSError:
                return None
    return (
        calibration_dir,
        os.path.join(calibration_dir, "sessions.tsv"),
        os.path.join(calibration_dir, "state"),
        os.path.join(calibration_dir, ".lock"),
    )


def _calibration_read_sessions(path):
    if not os.path.lexists(path):
        return {}
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    rows = {}
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if (
                    len(fields) != 4
                    or not re.match(r"^[0-9][0-9-]*[0-9]$", fields[0])
                    or not re.match(r"^[0-9]+$", fields[1])
                    or not re.match(r"^[0-9]+$", fields[2])
                    or not re.match(r"^[0-9]+$", fields[3])
                ):
                    return None
                rows[fields[0]] = (int(fields[1]), int(fields[2]), int(fields[3]))
    except (OSError, ValueError):
        return None
    return rows


def _calibration_read_state(path):
    state = {"prompted_key": "", "applied_key": ""}
    if not os.path.lexists(path):
        return state
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    seen = set()
    try:
        with open(path, encoding="utf-8", newline="") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("=", 1)
                if (
                    len(fields) != 2
                    or fields[0] not in state
                    or fields[0] in seen
                    or not re.match(r"^[0-9-]*$", fields[1])
                ):
                    return None
                state[fields[0]] = fields[1]
                seen.add(fields[0])
    except OSError:
        return None
    return state


def _calibration_write_atomic(path, text):
    if os.path.lexists(path) and os.path.islink(path):
        return False
    descriptor = None
    temporary = None
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=".calibration-state.", suffix=".tmp", dir=os.path.dirname(path)
        )
        if os.path.islink(temporary):
            os.close(descriptor)
            descriptor = None
            return False
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            descriptor = None
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
        return True
    except OSError:
        return False
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def sync_calibration_state(root, session_stats, min_sessions, min_turns, source_key):
    """Synchronize report session totals with the shell hook's state format."""
    paths = _calibration_state_paths(root)
    if paths is None:
        return False
    if (
        not isinstance(session_stats, dict)
        or not isinstance(source_key, str)
        or not isinstance(min_sessions, int)
        or isinstance(min_sessions, bool)
        or min_sessions <= 0
        or not isinstance(min_turns, int)
        or isinstance(min_turns, bool)
        or min_turns <= 0
    ):
        return False

    _calibration_dir, sessions_path, state_path, lock_path = paths
    if os.path.lexists(lock_path):
        return False
    try:
        os.mkdir(lock_path)
    except OSError:
        return False

    try:
        rows = _calibration_read_sessions(sessions_path)
        state = _calibration_read_state(state_path)
        if rows is None or state is None:
            return False
        now = int(time.time())
        positive_sample = False
        for session_id in sorted(session_stats):
            stats = session_stats[session_id]
            cache_read = getattr(stats, "cache_read", None)
            assistant_turns = getattr(stats, "assistant_turns", None)
            if (
                not isinstance(session_id, str)
                or not isinstance(cache_read, int)
                or isinstance(cache_read, bool)
                or cache_read < 0
                or not isinstance(assistant_turns, int)
                or isinstance(assistant_turns, bool)
                or assistant_turns < 0
            ):
                return False
            key = calibration_session_key(session_id, source_key)
            rows[key] = (cache_read, assistant_turns, now)
            positive_sample = positive_sample or cache_read > 0

        lines = []
        for key in sorted(rows):
            cache_read, assistant_turns, last_seen = rows[key]
            lines.append("{}\t{}\t{}\t{}".format(
                key, cache_read, assistant_turns, last_seen
            ))
        sessions_text = "\n".join(lines) + ("\n" if lines else "")
        if not _calibration_write_atomic(sessions_path, sessions_text):
            return False

        session_count = len(rows)
        assistant_turns = sum(row[1] for row in rows.values())
        prompt_key = calibration_prompt_key(
            session_count, assistant_turns, min_sessions, min_turns
        )
        prompt_available = (
            session_count >= min_sessions
            and assistant_turns >= min_turns
            and positive_sample
            and state["prompted_key"] != prompt_key
            and state["applied_key"] != prompt_key
        )
        if prompt_available:
            state["prompted_key"] = prompt_key
        state_text = "prompted_key={}\napplied_key={}\n".format(
            state["prompted_key"], state["applied_key"]
        )
        if not _calibration_write_atomic(state_path, state_text):
            return False
        return prompt_available
    except (OSError, TypeError, ValueError):
        return False
    finally:
        try:
            os.rmdir(lock_path)
        except OSError:
            pass


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
        self.main_tool_results = []
        self.compact_events = []
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
        # These are metadata-only indexes used while scanning.  They never enter
        # the report or snapshot, and do not retain prompt/tool-result bodies.
        self._tool_names = {}
        self._tool_result_session_keys = []
        self._tool_result_request_ids = []
        self._assistant_cache_reads = defaultdict(list)
        self._pending_compacts = defaultdict(list)
        self._compact_turns = defaultdict(int)


def safe_session_identifier(session_key):
    if not session_key:
        return "(不明)"
    digest = hashlib.sha256(str(session_key).encode("utf-8", "surrogateescape")).hexdigest()
    return "session-{}".format(digest[:10])


def safe_timestamp(value):
    stamp = parse_ts(value)
    if stamp is None:
        return "(不明)"
    return stamp.isoformat().replace("+00:00", "Z")


def serialized_byte_count(value):
    try:
        return len(
            json.dumps(
                value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            ).encode("utf-8")
        )
    except (TypeError, ValueError):
        return 0


def is_compact_message(message):
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if content == "/compact":
        return True
    for block in content_blocks(message):
        if isinstance(block, dict) and block.get("type") == "text":
            if block.get("text") == "/compact":
                return True
    return False


def record_compact(scan, session_key, timestamp):
    previous = scan._assistant_cache_reads.get(session_key, [])
    event = {
        "session": safe_session_identifier(session_key),
        "timestamp": safe_timestamp(timestamp),
        "pre_compact_baseline": median_non_negative_integer(previous[-3:]),
        "post_compact_usage": None,
        "recovery_turns": None,
    }
    scan.compact_events.append(event)
    event_index = len(scan.compact_events) - 1
    scan._pending_compacts[session_key].append(event_index)
    scan._compact_turns[event_index] = 0


def update_compact_events(scan, session_key, cache_read):
    values = scan._assistant_cache_reads.setdefault(session_key, [])
    values.append(cache_read)
    for event_index in scan._pending_compacts.get(session_key, []):
        event = scan.compact_events[event_index]
        if event["post_compact_usage"] is None:
            event["post_compact_usage"] = cache_read
        if event["recovery_turns"] is None:
            scan._compact_turns[event_index] += 1
            baseline = event["pre_compact_baseline"]
            if baseline is not None and cache_read * 10 >= baseline * 9:
                event["recovery_turns"] = scan._compact_turns[event_index]


def record_main_tool_results(scan, message, session_key, timestamp, request_id):
    for block in content_blocks(message):
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        tool_use_id = block.get("tool_use_id")
        tool_name = scan._tool_names.get((session_key, tool_use_id), "(不明)")
        tool_name = sanitize_name(tool_name) or "(不明)"
        scan.main_tool_results.append({
            "tool": tool_name,
            "session": safe_session_identifier(session_key),
            "timestamp": safe_timestamp(timestamp),
            "payload_bytes": serialized_byte_count(block.get("content")),
            "usage_matched": False,
        })
        scan._tool_result_session_keys.append(session_key)
        scan._tool_result_request_ids.append(request_id)


def mark_matching_tool_results(scan, session_key, request_id):
    if request_id is None:
        return
    for index, result_session in enumerate(scan._tool_result_session_keys):
        if (
            result_session == session_key
            and scan._tool_result_request_ids[index] == request_id
        ):
            scan.main_tool_results[index]["usage_matched"] = True


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
                accepted_main_usage = False
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
                                update_compact_events(scan, session_key, one.cache_read)
                            model = sanitize_model(message.get("model")) or "(不明)"
                            scan.by_model[model] += one
                            accepted_main_usage = True

                    for block in content_blocks(message):
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        name = str(block.get("name") or "(不明)")
                        scan.tool_calls[name] += 1
                        tool_use_id = block.get("id")
                        if session_key and isinstance(tool_use_id, str) and tool_use_id:
                            scan._tool_names[(session_key, tool_use_id)] = name
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

                if (
                    entry.get("type") == "user"
                    and session_key
                    and is_compact_message(message)
                ):
                    record_compact(scan, session_key, entry.get("timestamp"))
                request_id = dedup_scalar(entry.get("requestId"))
                record_main_tool_results(
                    scan, message, session_key, entry.get("timestamp"), request_id
                )
                if accepted_main_usage and session_key:
                    mark_matching_tool_results(scan, session_key, request_id)

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


def read_mcp_server_definitions(plugin_root):
    definitions = []
    sources = [os.path.join(plugin_root, ".mcp.json")]
    manifest = read_json(os.path.join(plugin_root, ".claude-plugin", "plugin.json"))
    if isinstance(manifest, dict):
        declared = manifest.get("mcpServers")
        if isinstance(declared, dict):
            definitions.extend(declared.items())
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
            definitions.extend(servers.items())
    out = []
    for key, definition in definitions:
        name = sanitize_name(key) if isinstance(key, str) else None
        if name:
            out.append((name, definition))
    return out


def read_mcp_server_names(plugin_root):
    return [name for name, _definition in read_mcp_server_definitions(plugin_root)]


def plugin_mcp_definitions():
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
            for name, definition in read_mcp_server_definitions(root):
                rows.append((f"plugin:{plugin_name}", name, definition))
    return rows


def plugin_mcp_servers():
    return [(scope, name) for scope, name, _definition in plugin_mcp_definitions()]


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


def mcp_definition_rows():
    sources = [("user", path) for path in config_json_candidates()]
    sources.append(("project", project_path(".mcp.json")))
    rows = []
    seen = set()
    for scope, source in sources:
        data = read_json(source)
        if not isinstance(data, dict):
            continue
        servers = data.get("mcpServers")
        if not isinstance(servers, dict):
            continue
        for raw_name, definition in servers.items():
            name = sanitize_name(raw_name)
            if not name or (scope, name) in seen:
                continue
            seen.add((scope, name))
            rows.append({
                "scope": scope,
                "name": name,
                "definition_bytes": serialized_byte_count(definition),
            })
    for scope, name, definition in plugin_mcp_definitions():
        if (scope, name) in seen:
            continue
        seen.add((scope, name))
        rows.append({
            "scope": scope,
            "name": name,
            "definition_bytes": serialized_byte_count(definition),
        })
    return rows


def classify_unused_mcp(configured, used):
    configured_names = []
    for item in configured:
        if isinstance(item, (tuple, list)) and len(item) >= 2:
            item = item[1]
        name = sanitize_name(item)
        if name and name not in configured_names:
            configured_names.append(name)

    if hasattr(used, "keys"):
        used_names = list(used.keys())
    else:
        used_names = list(used or [])
    used_normalized = {
        normalize_server_name(name)
        for name in used_names
        if isinstance(name, str) and normalize_server_name(name)
    }
    by_normalized = defaultdict(list)
    for name in configured_names:
        normalized = normalize_server_name(name)
        if normalized:
            by_normalized[normalized].append(name)

    result = {"unused": [], "used": [], "unknown": []}
    for name in configured_names:
        normalized = normalize_server_name(name)
        matches = by_normalized.get(normalized, [])
        if len(matches) != 1:
            result["unknown"].append(name)
        elif normalized in used_normalized:
            result["used"].append(name)
        else:
            result["unused"].append(name)
    return result


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


def build_diagnostics(scan, calibration, main_paths, sub_paths):
    recommended = calibration.get("recommended_levels", []) if calibration else []
    level_two = recommended[1] if len(recommended) >= 2 else None
    main_total = scan.main.total

    heavy = [
        dict(result)
        for result in scan.main_tool_results
        if result["payload_bytes"] >= HEAVY_TOOL_RESULT_BYTES
    ]
    heavy.sort(key=lambda result: -result["payload_bytes"])
    sessions = []
    if level_two is not None:
        for session_key, stats in scan.session_stats.items():
            if stats.cache_read < level_two:
                continue
            ratio = (stats.cache_read / float(main_total)) if main_total else 0.0
            sessions.append({
                "session": safe_session_identifier(session_key),
                "cache_read": stats.cache_read,
                "main_ratio": ratio,
            })
    sessions.sort(key=lambda row: (-row["cache_read"], row["session"]))

    used = mcp_tool_prefixes(scan.tool_calls)
    if scan.sub_mcp_calls:
        used += mcp_tool_prefixes(scan.sub_mcp_calls)
    mcp_rows = mcp_definition_rows()
    configured = [row["name"] for row in mcp_rows]
    mcp_classification = classify_unused_mcp(configured, used)

    agent_ratio = (scan.agent_total / float(main_total)) if main_total else 0.0
    compact_events = []
    for event in scan.compact_events:
        compact_events.append({
            "session": event["session"],
            "timestamp": event["timestamp"],
            "pre_compact_baseline": event["pre_compact_baseline"],
            "post_compact_usage": event["post_compact_usage"],
            "recovery_turns": event["recovery_turns"],
        })

    return {
        "measured": {
            "main_total": main_total,
            "heavy_tool_results": heavy,
            "sessions_exceeding_level2": sessions,
            "mcp": mcp_classification,
            "agent_calls": sum(scan.agent_calls.values()),
            "agent_results": sum(scan.agent_results.values()),
            "agent_total_tokens": scan.agent_total,
            "agent_main_ratio": agent_ratio,
            "compact_events": compact_events,
            "image_tokens": "未計測",
        },
        "estimated": {
            "mcp_definitions": [
                {
                    "scope": row["scope"],
                    "name": row["name"],
                    "definition_bytes": row["definition_bytes"],
                    "estimated_tokens": row["definition_bytes"] / 4.0,
                }
                for row in mcp_rows
            ],
            "method": "定義バイト数 ÷ 4 の概算。実測合計へ加算しない。",
        },
    }


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


def append_calibration_prompt(lines):
    lines.append(
        "- キャリブレーションのサンプル条件を満たしました。内容を確認してから明示適用してください。"
    )
    lines.append(
        "- `./{}/token-report.sh --calibrate`".format(TOKEN_SAVER_DIRNAME)
    )
    lines.append(
        "- `./{}/token-calibrate.sh --apply`".format(TOKEN_SAVER_DIRNAME)
    )


def build_report(
    args,
    scan,
    project_dirs,
    since,
    calibration=None,
    diagnostics=None,
    calibration_prompt=False,
):
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
        if calibration.get("prompt_available"):
            append_calibration_prompt(lines)
        add("")

    if diagnostics is not None:
        measured = diagnostics["measured"]
        estimated = diagnostics["estimated"]
        add("## 実測診断")
        add("")
        heavy = measured["heavy_tool_results"]
        add(
            "- 重い main tool_result: {} 件（payload {} bytes 以上）".format(
                len(heavy), fmt(HEAVY_TOOL_RESULT_BYTES)
            )
        )
        if heavy:
            rows = []
            for result in heavy[: args.top]:
                rows.append([
                    result["tool"],
                    result["session"],
                    result["timestamp"],
                    fmt(result["payload_bytes"]),
                    "usage対応あり" if result["usage_matched"] else "usage対応なし",
                ])
            lines.extend(
                table(
                    ["tool", "session", "時刻", "payload bytes", "usage"], rows
                )
            )
        else:
            add("（重い main tool_result はなし）")
            add("")

        sessions = measured["sessions_exceeding_level2"]
        add("- 推奨段階2以上の超過セッション: {} 件".format(len(sessions)))
        if sessions:
            lines.extend(
                table(
                    ["超過セッション", "cache_read", "main消費比"],
                    [
                        [
                            row["session"],
                            fmt(row["cache_read"]),
                            "{:.1%}".format(row["main_ratio"]),
                        ]
                        for row in sessions[: args.top]
                    ],
                )
            )

        compact_events = measured["compact_events"]
        add("- /compact 発生: {} 件".format(len(compact_events)))
        if compact_events:
            lines.extend(
                table(
                    ["session", "時刻", "圧縮前基準", "圧縮直後usage", "回復ターン数"],
                    [
                        [
                            event["session"],
                            event["timestamp"],
                            fmt(event["pre_compact_baseline"])
                            if event["pre_compact_baseline"] is not None
                            else "未算出",
                            fmt(event["post_compact_usage"])
                            if event["post_compact_usage"] is not None
                            else "未取得",
                            event["recovery_turns"]
                            if event["recovery_turns"] is not None
                            else "未回復",
                        ]
                        for event in compact_events[: args.top]
                    ],
                )
            )
            for event in compact_events[: args.top]:
                recovery = (
                    event["recovery_turns"]
                    if event["recovery_turns"] is not None
                    else "未回復"
                )
                add("- compact回復ターン数: {}".format(recovery))

        mcp = measured["mcp"]
        add("- MCP分類（実測呼び出しベース）:")
        for category in ("unused", "used", "unknown"):
            names = mcp.get(category, [])
            add(
                "  - {}: {}".format(
                    {"unused": "未使用MCP", "used": "利用済みMCP", "unknown": "判定不能MCP"}[category],
                    ", ".join(markdown_cell(name) for name in names) or "該当なし",
                )
            )
        add(
            "- Agent: 起動 {} 件 / 結果 {} 件 / totalTokens {} / main比 {:.1%}".format(
                fmt(measured["agent_calls"]),
                fmt(measured["agent_results"]),
                fmt(measured["agent_total_tokens"]),
                measured["agent_main_ratio"],
            )
        )
        add("- 画像入力のトークン消費は未計測です（画像を数値推定していない）。")
        add("")

        add("## 概算診断")
        add("")
        add("- 概算値は実測合計・中央値・MCP未使用判定へ混ぜない。")
        add("- 算出方法: {}".format(estimated["method"]))
        definition_rows = [
            [
                row["scope"],
                row["name"],
                fmt(row["definition_bytes"]),
                "{:.1f}".format(row["estimated_tokens"]),
            ]
            for row in estimated["mcp_definitions"]
        ]
        lines.extend(
            table(
                ["スコープ", "MCPサーバ名", "定義bytes", "推定tokens"],
                definition_rows[: args.top],
            )
        )
        add("")

    if calibration_prompt and calibration is None:
        add("## キャリブレーション案内")
        add("")
        append_calibration_prompt(lines)
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
    calibration_state = build_calibration(scan, args, since, main_paths, sub_paths)
    calibration = calibration_state if args.calibrate else None
    if args.calibrate:
        if not write_calibration_snapshot(calibration):
            print("キャリブレーション snapshot の保存に失敗しました", file=sys.stderr)
            return 1
    diagnostics = (
        build_diagnostics(scan, calibration, main_paths, sub_paths)
        if args.calibrate
        else None
    )
    report = build_report(
        args,
        scan,
        [PROJECT_ROOT],
        since,
        calibration,
        diagnostics,
        calibration_state.get("prompt_available", False),
    )

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
