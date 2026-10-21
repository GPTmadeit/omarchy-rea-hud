#!/usr/bin/env python3
"""Claude Code hook: records REA (mcp__rea__*) tool activity for the REA HUD.

Wired to PreToolUse / PostToolUse / PostToolUseFailure. Reads the hook payload
on stdin and maintains ~/.local/state/rea-hud/state.json, which the
rea-hud shell plugin watches. Never blocks or fails the tool call.
"""
import fcntl
import json
import os
import sys
import time

STATE_DIR = os.path.expanduser("~/.local/state/rea-hud")
STATE = os.path.join(STATE_DIR, "state.json")
PREFIX = "mcp__rea__"
STALE_MS = 30 * 60 * 1000
MAX_RECENT = 6
MAX_FILES = 8

# Input keys that name what a job is acting on, most descriptive first.
DETAIL_KEYS = ("name", "function", "procedure", "address", "symbol", "query",
               "pattern", "command", "class_name", "method", "package", "url",
               "target", "expression", "script")
WRITE_HINTS = ("out", "dest", "export", "save", "snapshot", "write", "local")


def now_ms():
    return int(time.time() * 1000)


def collect_paths(value, key="", found=None):
    """Walk tool_input for strings that look like filesystem paths."""
    if found is None:
        found = []
    if isinstance(value, dict):
        for k, v in value.items():
            collect_paths(v, str(k), found)
    elif isinstance(value, list):
        for v in value:
            collect_paths(v, key, found)
    elif isinstance(value, str):
        s = value.strip()
        if (s.startswith("/") or s.startswith("~/")) and "\n" not in s and len(s) < 512:
            mode = "write" if any(h in key.lower() for h in WRITE_HINTS) else "read"
            found.append({"path": os.path.expanduser(s), "mode": mode, "key": key})
    return found


def detail_for(tool_input):
    if not isinstance(tool_input, dict):
        return ""
    for k in DETAIL_KEYS:
        v = tool_input.get(k)
        if isinstance(v, (str, int, float)) and str(v).strip():
            s = str(v).strip().splitlines()[0]
            return s if len(s) <= 80 else s[:77] + "..."
    return ""


def error_message(raw):
    """REA errors arrive as a JSON envelope; surface just the human message."""
    text = str(raw or "")
    try:
        err = json.loads(text).get("error", {})
        text = err.get("message") or err.get("code") or text
    except (ValueError, AttributeError):
        pass
    return text[:200]


def load(fh):
    fh.seek(0)
    try:
        data = json.loads(fh.read() or "{}")
    except ValueError:
        data = {}
    data.setdefault("active", [])
    data.setdefault("recent", [])
    data.setdefault("files", [])
    return data


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    tool = payload.get("tool_name") or ""
    if not tool.startswith(PREFIX):
        return
    event = payload.get("hook_event_name") or ""
    tool_input = payload.get("tool_input") or {}
    job_id = payload.get("tool_use_id") or "%s:%s" % (tool, json.dumps(tool_input, sort_keys=True))
    short = tool[len(PREFIX):]
    t = now_ms()

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(os.path.join(STATE_DIR, ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(STATE) as fh:
                data = load(fh)
        except FileNotFoundError:
            data = load(open(os.devnull))

        data["active"] = [j for j in data["active"] if t - j.get("started", 0) < STALE_MS]

        if event == "PreToolUse":
            paths = collect_paths(tool_input)
            data["active"].append({
                "id": job_id,
                "tool": short,
                "detail": detail_for(tool_input),
                "paths": paths,
                "session": payload.get("session_id", ""),
                "started": t,
            })
            seen = {f["path"] for f in paths}
            data["files"] = (paths + [f for f in data["files"] if f["path"] not in seen])[:MAX_FILES]
            if short in ("open_binary", "inspect_artifact", "extract_artifact", "extract_firmware") and paths:
                data["target"] = paths[0]["path"]
        else:
            job = next((j for j in data["active"] if j["id"] == job_id), None)
            data["active"] = [j for j in data["active"] if j["id"] != job_id]
            ok = event == "PostToolUse"
            started = job["started"] if job else t
            data["recent"] = ([{
                "tool": short,
                "detail": job["detail"] if job else detail_for(tool_input),
                "ok": ok,
                "ms": t - started,
                "ended": t,
            }] + data["recent"])[:MAX_RECENT]
            if not ok:
                data["lastError"] = {"tool": short, "error": error_message(payload.get("error", "")), "at": t}
            if short == "close_binary":
                data.pop("target", None)

        data["updated"] = t
        tmp = STATE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, STATE)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
