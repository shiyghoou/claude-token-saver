#!/usr/bin/env python3
"""Validate and explicitly apply a calibration snapshot.

This command is deliberately separate from the read-only measurement engine.
Only the two session-cut thresholds and calibration.last_applied are changed.
"""

import datetime
import json
import os
import re
import runpy
import sys


ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB_DIR = os.path.join(ROOT_DIR, "lib")
if LIB_DIR not in sys.path:
    sys.path.insert(0, LIB_DIR)

import ledger


DEFAULT_SESSION_CUT = 30000000
TOKEN_SAVER_DIRNAME = ".token" + "-saver"
CALIBRATION_DEFAULTS = {
    "min_sessions": 5,
    "min_assistant_turns": 100,
    "percentile": 75,
    "exclude_below_assistant_turns": 3,
}
CALIBRATION_MAX = 1000000
FINGERPRINT_RE = re.compile(r"^[0-9a-f]{64}$")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$")
PROMPT_KEY_RE = re.compile(r"^[0-9][0-9-]*[0-9]$")


class CalibrationError(Exception):
    pass


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def non_negative_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def calibration_source(settings):
    source = "メインセッションの重複排除後 cache_read p{}".format(
        settings["percentile"]
    )
    exclude = settings["exclude_below_assistant_turns"]
    if exclude == 0:
        return source
    return "{}（assistant_turns>={} を母集団）".format(source, exclude)


def _valid_calibration_setting(key, value):
    if key == "percentile":
        return (
            isinstance(value, int)
            and not isinstance(value, bool)
            and 1 <= value <= 99
        )
    if key == "exclude_below_assistant_turns":
        return (
            isinstance(value, int)
            and not isinstance(value, bool)
            and 0 <= value <= CALIBRATION_MAX
        )
    return positive_integer(value)


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


def calibration_prompt_key(snapshot):
    expected = "{}-{}-{}-{}".format(
        snapshot["session_count"],
        snapshot["assistant_turns"],
        snapshot["min_sessions"],
        snapshot["min_assistant_turns"],
    )
    supplied = snapshot.get("prompt_key")
    if supplied is not None:
        if (
            not isinstance(supplied, str)
            or not PROMPT_KEY_RE.match(supplied)
            or supplied != expected
        ):
            raise CalibrationError("snapshotのprompt keyが不正")
    return expected


def load_snapshot(path):
    """Return a validated eligible latest.json snapshot."""
    snapshot = _read_json(path)
    if snapshot.get("eligible") is not True:
        raise CalibrationError("snapshotが適用可能ではない")
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
        "sample_session_count",
        "assistant_turns",
        "baseline_cache_read",
        "current_initial",
        "current_increment",
        "percentile",
    ):
        if not positive_integer(snapshot.get(key)):
            raise CalibrationError("snapshotの数値が不正")
    if not _valid_calibration_setting(
        "percentile", snapshot["percentile"]
    ) or snapshot["percentile"] > 99:
        raise CalibrationError("snapshotの数値が不正")
    if not _valid_calibration_setting(
        "exclude_below_assistant_turns",
        snapshot.get("exclude_below_assistant_turns"),
    ):
        raise CalibrationError("snapshotの数値が不正")
    for key in ("total_session_count", "excluded_session_count"):
        if not non_negative_integer(snapshot.get(key)):
            raise CalibrationError("snapshotの数値が不正")
    if snapshot["sample_session_count"] != snapshot["session_count"]:
        raise CalibrationError("snapshotのsession数が不整合")
    if snapshot["total_session_count"] < snapshot["session_count"]:
        raise CalibrationError("snapshotのsession数が不整合")
    if snapshot["excluded_session_count"] > snapshot["total_session_count"]:
        raise CalibrationError("snapshotのsession数が不整合")

    distribution = snapshot.get("distribution")
    if not isinstance(distribution, dict):
        raise CalibrationError("snapshotの分布が不正")
    for key in ("p50", "p75", "p90", "p95"):
        value = distribution.get(key)
        if value is not None and not positive_integer(value):
            raise CalibrationError("snapshotの分布が不正")

    concentration = snapshot.get("concentration")
    if not isinstance(concentration, dict):
        raise CalibrationError("snapshotの集中度が不正")
    if concentration.get("top_n") != 3:
        raise CalibrationError("snapshotの集中度が不正")
    share = concentration.get("share")
    if not isinstance(share, (int, float)) or isinstance(share, bool) or not 0 <= share <= 1:
        raise CalibrationError("snapshotの集中度が不正")
    for key in ("cache_read_sum_top", "cache_read_sum_all"):
        if not non_negative_integer(concentration.get(key)):
            raise CalibrationError("snapshotの集中度が不正")
    if concentration["cache_read_sum_top"] > concentration["cache_read_sum_all"]:
        raise CalibrationError("snapshotの集中度が不正")

    expected_source = calibration_source(
        {
            "percentile": snapshot["percentile"],
            "exclude_below_assistant_turns": snapshot[
                "exclude_below_assistant_turns"
            ],
        }
    )
    if snapshot.get("source") != expected_source:
        raise CalibrationError("snapshotの算出元が不正")

    if not isinstance(snapshot.get("all_projects"), bool):
        raise CalibrationError("snapshotの対象選択が不正")
    if (
        not isinstance(snapshot.get("scan_days"), int)
        or isinstance(snapshot["scan_days"], bool)
        or snapshot["scan_days"] < 0
    ):
        raise CalibrationError("snapshotの対象期間が不正")
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
    calibration_prompt_key(snapshot)
    return snapshot


def validate_scan_identity(root, snapshot):
    """Recompute the private scan identity without exposing input paths."""
    previous_cwd = os.getcwd()
    try:
        os.chdir(root)
        engine = runpy.run_path(os.path.join(ROOT_DIR, "scripts", "measure-token-usage.py"))
        args = type("CalibrationArgs", (object,), {})()
        args.days = snapshot["scan_days"]
        args.all_projects = snapshot["all_projects"]
        since = None if args.days == 0 else object()
        settings = {
            "min_sessions": snapshot["min_sessions"],
            "min_assistant_turns": snapshot["min_assistant_turns"],
            "percentile": snapshot["percentile"],
            "exclude_below_assistant_turns": snapshot[
                "exclude_below_assistant_turns"
            ],
        }
        project_dirs, fell_back = engine["select_project_dirs"](args)
        main_paths, sub_paths = engine["transcript_paths"](project_dirs)
        current = engine["calibration_fingerprint"](
            args,
            since,
            settings,
            main_paths,
            sub_paths,
            project_dirs,
            fell_back,
        )
    except (KeyError, OSError, TypeError, ValueError, ImportError):
        raise CalibrationError("対象の識別情報を検証できない")
    finally:
        os.chdir(previous_cwd)
    if current != snapshot["fingerprint"]:
        raise CalibrationError("対象がsnapshot作成時から変化した")


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
            if not _valid_calibration_setting(key, value):
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


def _calibration_state_path(config_path):
    root = os.path.dirname(os.path.dirname(os.path.abspath(config_path)))
    _reject_symlink_components(root)
    state_dir = os.path.join(root, TOKEN_SAVER_DIRNAME, "calibration")
    _reject_symlink_components(state_dir)
    if not os.path.isdir(state_dir) or os.path.islink(state_dir):
        raise CalibrationError("calibration stateの親ディレクトリが不正")
    return os.path.join(state_dir, "state"), os.path.join(state_dir, ".lock")


def _read_calibration_state(path):
    state = {"prompted_key": "", "applied_key": ""}
    if not os.path.lexists(path):
        return state
    _regular_file(path)
    seen = set()
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                fields = line.rstrip("\n").split("=", 1)
                if (
                    len(fields) != 2
                    or fields[0] not in state
                    or fields[0] in seen
                    or not re.match(r"^[0-9-]*$", fields[1])
                ):
                    raise CalibrationError("calibration stateが不正")
                state[fields[0]] = fields[1]
                seen.add(fields[0])
    except OSError:
        raise CalibrationError("calibration stateを読めない")
    return state


def _read_bytes(path):
    _regular_file(path)
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        raise CalibrationError("ファイルを読み取れない")


def _acquire_calibration_state(config_path, snapshot):
    state_path, lock_path = _calibration_state_path(config_path)
    if os.path.lexists(lock_path):
        raise CalibrationError("calibration stateがロックされている")
    try:
        os.mkdir(lock_path)
    except OSError:
        raise CalibrationError("calibration stateのロックを取得できない")
    try:
        state = _read_calibration_state(state_path)
        state_existed = os.path.lexists(state_path)
        state_before = _read_bytes(state_path) if state_existed else None
        state["applied_key"] = calibration_prompt_key(snapshot)
        ledger.check_writable(state_path)
        return {
            "state_path": state_path,
            "lock_path": lock_path,
            "state_existed": state_existed,
            "state_before": state_before,
            "text": "prompted_key={}\napplied_key={}\n".format(
                state["prompted_key"], state["applied_key"]
            ),
        }
    except Exception:
        try:
            os.rmdir(lock_path)
        except OSError:
            pass
        raise


def _write_calibration_state(context):
    ledger.write_atomic(context["state_path"], context["text"])


def _release_calibration_state(context):
    try:
        os.rmdir(context["lock_path"])
    except OSError:
        pass


def record_applied_key(config_path, snapshot):
    context = _acquire_calibration_state(config_path, snapshot)
    try:
        _write_calibration_state(context)
    finally:
        _release_calibration_state(context)


def _restore_file(path, existed, content):
    if existed:
        ledger.write_atomic(path, content.decode("utf-8", "surrogateescape"))
    elif os.path.lexists(path):
        if os.path.islink(path):
            raise CalibrationError("復元対象がsymlinkになった")
        os.unlink(path)


def _preview(current, snapshot):
    print(
        "現在値: initial {} / increment {} cache_read".format(
            current["initial_cache_read"], current["increment_cache_read"]
        )
    )
    print(
        "推奨値: initial {} / increment {} cache_read".format(
            snapshot["baseline_cache_read"], snapshot["baseline_cache_read"]
        )
    )


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
        config_existed = os.path.lexists(config_path)
        config_before = _read_bytes(config_path) if config_existed else None
        if os.path.lexists(config_path):
            config = _read_json(config_path)
            current = validate_current_config(config, snapshot)
        else:
            if not os.path.isdir(os.path.dirname(config_path)):
                raise CalibrationError("configの親ディレクトリが通常ディレクトリではない")
            current = {
                "initial_cache_read": snapshot["current_initial"],
                "increment_cache_read": snapshot["current_increment"],
            }
        validate_scan_identity(root, snapshot)
        state_context = _acquire_calibration_state(config_path, snapshot)
        try:
            _preview(current, snapshot)
            apply_snapshot(config_path, snapshot)
            _write_calibration_state(state_context)
        except Exception:
            _restore_file(config_path, config_existed, config_before)
            _restore_file(
                state_context["state_path"],
                state_context["state_existed"],
                state_context["state_before"],
            )
            raise
        finally:
            _release_calibration_state(state_context)
    except CalibrationError as e:
        sys.stderr.write("キャリブレーションを適用できません: {}\n".format(e))
        return 1
    except (OSError, TypeError, ValueError) as e:
        sys.stderr.write("キャリブレーションを適用できません: {}\n".format(type(e).__name__))
        return 1
    print("キャリブレーションを適用しました")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
