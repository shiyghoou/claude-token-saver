#!/usr/bin/env python3
"""Validate and explicitly apply a calibration snapshot.

This command is deliberately separate from the read-only measurement engine.
Only the two session-cut thresholds and calibration.last_applied are changed.
"""

import datetime
import json
import os
import re
import sys


ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(ROOT_DIR, "lib")
if LIB_DIR not in sys.path:
    sys.path.insert(0, LIB_DIR)

import ledger


DEFAULT_SESSION_CUT = 30000000
CALIBRATION_DEFAULTS = {"min_sessions": 5, "min_assistant_turns": 100}
CALIBRATION_SOURCE = "メインセッションの重複排除後 cache_read 中央値"
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$")


class CalibrationError(Exception):
    pass


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _reject_symlink_components(path):
    absolute = os.path.abspath(path)
    current = os.path.sep
    for component in absolute.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        if os.path.islink(current):
            raise CalibrationError("安全でないシンボリックリンクを検出した")


def _regular_file(path):
    _reject_symlink_components(path)
    if not os.path.isfile(path):
        raise CalibrationError("必要なファイルが通常ファイルではない")


def _read_json(path):
    _regular_file(path)
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        raise CalibrationError("JSONを読み込めない")
    if not isinstance(value, dict):
        raise CalibrationError("JSONのrootがobjectではない")
    return value


def _validate_timestamp(value):
    if not isinstance(value, str) or not TIMESTAMP_RE.match(value):
        raise CalibrationError("generated_atが不正")
    try:
        datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")
    except ValueError:
        raise CalibrationError("generated_atが不正")


def load_snapshot(path):
    """Return a validated eligible latest.json snapshot."""
    snapshot = _read_json(path)
    if snapshot.get("eligible") is not True:
        raise CalibrationError("snapshotが適用可能ではない")
    if snapshot.get("source") != CALIBRATION_SOURCE:
        raise CalibrationError("snapshotの算出元が不正")
    _validate_timestamp(snapshot.get("generated_at"))
    fingerprint = snapshot.get("fingerprint")
    if not isinstance(fingerprint, str) or not FINGERPRINT_RE.match(fingerprint):
        raise CalibrationError("snapshotの識別情報が不正")
    if not isinstance(snapshot.get("period"), str) or not snapshot["period"]:
        raise CalibrationError("snapshotの対象期間が不正")

    for key in (
        "min_sessions",
        "min_assistant_turns",
        "session_count",
        "assistant_turns",
        "baseline_cache_read",
        "current_initial",
        "current_increment",
    ):
        if not positive_integer(snapshot.get(key)):
            raise CalibrationError("snapshotの数値が不正")
    if snapshot["session_count"] < snapshot["min_sessions"]:
        raise CalibrationError("snapshotのsession数が条件未達")
    if snapshot["assistant_turns"] < snapshot["min_assistant_turns"]:
        raise CalibrationError("snapshotのassistant数が条件未達")

    levels = snapshot.get("recommended_levels")
    if not isinstance(levels, list) or len(levels) != 3:
        raise CalibrationError("snapshotの推奨値が不正")
    if not all(positive_integer(value) for value in levels):
        raise CalibrationError("snapshotの推奨値が不正")
    baseline = snapshot["baseline_cache_read"]
    if levels != [baseline, baseline * 2, baseline * 3]:
        raise CalibrationError("snapshotの推奨値が不整合")
    return snapshot


def _current_calibration_settings(config):
    calibration = config.get("calibration")
    if calibration is None:
        return dict(CALIBRATION_DEFAULTS), None
    if not isinstance(calibration, dict):
        raise CalibrationError("calibrationがobjectではない")
    values = dict(CALIBRATION_DEFAULTS)
    for key, default in CALIBRATION_DEFAULTS.items():
        if key in calibration:
            value = calibration[key]
            if not positive_integer(value):
                raise CalibrationError("calibrationの判定条件が不正")
            values[key] = value
        else:
            values[key] = default
    return values, calibration


def validate_current_config(config, snapshot):
    """Validate current config identity and return its active threshold values."""
    if not isinstance(config, dict):
        raise CalibrationError("configのrootがobjectではない")
    if "suggest_session_cut" not in config:
        raise CalibrationError("suggest_session_cutが無い")
    session_cut = config.get("suggest_session_cut")
    if not isinstance(session_cut, dict):
        raise CalibrationError("suggest_session_cutがobjectではない")
    current = {}
    for key in ("initial_cache_read", "increment_cache_read"):
        value = session_cut.get(key)
        if not positive_integer(value):
            raise CalibrationError("suggest_session_cutの閾値が不正")
        current[key] = value
    if current["initial_cache_read"] != snapshot["current_initial"]:
        raise CalibrationError("initial_cache_readがsnapshot作成時から変化した")
    if current["increment_cache_read"] != snapshot["current_increment"]:
        raise CalibrationError("increment_cache_readがsnapshot作成時から変化した")

    settings, _calibration = _current_calibration_settings(config)
    for key in CALIBRATION_DEFAULTS:
        if settings[key] != snapshot[key]:
            raise CalibrationError("calibrationの判定条件がsnapshot作成時から変化した")
    return current


def _safe_config_path(root):
    if not isinstance(root, str) or not os.path.isabs(root):
        raise CalibrationError("rootが絶対パスではない")
    _reject_symlink_components(root)
    claude_dir = os.path.join(root, ".claude")
    _reject_symlink_components(claude_dir)
    if not os.path.isdir(claude_dir) or os.path.islink(claude_dir):
        raise CalibrationError(".claudeが通常ディレクトリではない")
    return os.path.join(claude_dir, "token-saver.json")


def _load_current_config(config_path):
    if not os.path.lexists(config_path):
        return {}, False
    return _read_json(config_path), True


def _last_applied(snapshot, current):
    return {
        "source": snapshot["source"],
        "generated_at": snapshot["generated_at"],
        "period": snapshot["period"],
        "fingerprint": snapshot["fingerprint"],
        "sample_count": snapshot["session_count"],
        "assistant_turns": snapshot["assistant_turns"],
        "previous_initial": current["initial_cache_read"],
        "previous_increment": current["increment_cache_read"],
        "recommended_initial": snapshot["baseline_cache_read"],
        "recommended_increment": snapshot["baseline_cache_read"],
    }


def apply_snapshot(config_path, snapshot):
    """Apply a validated snapshot to config_path and return the new config."""
    _reject_symlink_components(config_path)
    if os.path.lexists(config_path) and os.path.islink(config_path):
        raise CalibrationError("configがsymlinkである")
    config, existed = _load_current_config(config_path)
    if not existed:
        config = {
            "suggest_session_cut": {
                "initial_cache_read": DEFAULT_SESSION_CUT,
                "increment_cache_read": DEFAULT_SESSION_CUT,
            }
        }
    current = validate_current_config(config, snapshot)

    session_cut = config["suggest_session_cut"]
    session_cut["initial_cache_read"] = snapshot["baseline_cache_read"]
    session_cut["increment_cache_read"] = snapshot["baseline_cache_read"]
    calibration = config.get("calibration")
    if calibration is None:
        calibration = {}
        config["calibration"] = calibration
    if not isinstance(calibration, dict):
        raise CalibrationError("calibrationがobjectではない")
    calibration["last_applied"] = _last_applied(snapshot, current)

    try:
        ledger.check_writable(config_path)
        ledger.write_atomic(config_path, json.dumps(config, ensure_ascii=False, indent=2) + "\n")
    except (OSError, TypeError, ValueError):
        raise CalibrationError("configを原子的に更新できない")

    written = _read_json(config_path)
    if written.get("suggest_session_cut", {}).get("initial_cache_read") != snapshot["baseline_cache_read"]:
        raise CalibrationError("更新後のinitial_cache_readを検証できない")
    if written.get("suggest_session_cut", {}).get("increment_cache_read") != snapshot["baseline_cache_read"]:
        raise CalibrationError("更新後のincrement_cache_readを検証できない")
    return written


def main(argv):
    if len(argv) != 4 or set(argv[::2]) != {"--root", "--latest"}:
        sys.stderr.write("usage: apply-token-calibration.py --root ROOT --latest LATEST\n")
        return 64
    root = argv[argv.index("--root") + 1]
    latest = argv[argv.index("--latest") + 1]
    try:
        snapshot = load_snapshot(latest)
        config_path = _safe_config_path(root)
        if os.path.lexists(config_path):
            config = _read_json(config_path)
            validate_current_config(config, snapshot)
        else:
            if not os.path.isdir(os.path.dirname(config_path)):
                raise CalibrationError("configの親ディレクトリが通常ディレクトリではない")
        apply_snapshot(config_path, snapshot)
    except (CalibrationError, OSError):
        sys.stderr.write("キャリブレーションを適用できません\n")
        return 1
    print("キャリブレーションを適用しました")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
