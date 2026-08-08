#!/usr/bin/env python3
"""Scripted simpleplug daemon for the install/update batch tests.

The real daemon is the wrong tool here: these tests are about what the Vim
side does with a batch's events, so they need those events to be exactly
reproducible — a named plugin that fails, another that is frozen, a checkout
that appears on disk — without a network, a git server or a clock.

Requests answered
  {"type":"ping","id":N}                    -> pong (protocol 2, real caps)
  {"type":"install"|"update","id":N,...}    -> progress per plugin, then done

Environment
  FAKE_PLUG_FAIL      comma-separated plugin names to report as errors
  FAKE_PLUG_FROZEN    comma-separated plugin names to report as skipped/frozen
  FAKE_PLUG_SILENT    if set, answer the handshake and nothing else
  FAKE_PLUG_DELAY_MS  wait this long before the first progress event
  FAKE_PLUG_DUMP      append every request to this file, one JSON line each,
                      so a test can assert on what actually went over the wire

A plugin's checkout is materialised by copying `<dir>.src` to `<dir>` when that
template exists, which is how a test arranges for a plugin to become loadable
only once the "clone" reports success.
"""

import json
import os
import shutil
import sys
import time

PROTOCOL_VERSION = 2
CAPABILITIES = [
    "install",
    "update",
    "clean",
    "status",
    "post_hook",
    "tag_pin",
    "commit_pin",
    "submodules",
]


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def names_from_env(key):
    return {n for n in os.environ.get(key, "").split(",") if n}


def handle_batch(req):
    kind = req["type"]
    rid = req.get("id", 0)
    failing = names_from_env("FAKE_PLUG_FAIL")
    frozen = names_from_env("FAKE_PLUG_FROZEN")
    delay = float(os.environ.get("FAKE_PLUG_DELAY_MS", "0")) / 1000.0
    if delay:
        time.sleep(delay)

    summary = {"installed": 0, "updated": 0, "already_ok": 0, "errors": 0}
    for plugin in req.get("plugins", []):
        name = plugin["name"]
        emit(
            {
                "type": "progress",
                "id": rid,
                "name": name,
                "status": "working",
                "message": "checking installation",
            }
        )
        if name in failing:
            emit(
                {
                    "type": "progress",
                    "id": rid,
                    "name": name,
                    "status": "error",
                    "message": "clone failed: fixture",
                }
            )
            summary["errors"] += 1
            continue
        if name in frozen:
            emit(
                {
                    "type": "progress",
                    "id": rid,
                    "name": name,
                    "status": "skipped",
                    "message": "frozen",
                }
            )
            summary["already_ok"] += 1
            continue
        template = plugin["dir"] + ".src"
        if os.path.isdir(template) and not os.path.exists(plugin["dir"]):
            shutil.copytree(template, plugin["dir"])
        status = "installed" if kind == "install" else "updated"
        emit(
            {
                "type": "progress",
                "id": rid,
                "name": name,
                "status": status,
                "message": "cloned" if kind == "install" else "0000000 → 1111111",
            }
        )
        summary[status] += 1
    emit({"type": "done", "id": rid, "summary": summary})


def main():
    silent = bool(os.environ.get("FAKE_PLUG_SILENT"))
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        dump = os.environ.get("FAKE_PLUG_DUMP")
        if dump:
            with open(dump, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        kind = req.get("type")
        if kind == "ping":
            emit(
                {
                    "type": "pong",
                    "id": req.get("id", 0),
                    "protocol_version": PROTOCOL_VERSION,
                    "version": "fake",
                    "capabilities": {c: True for c in CAPABILITIES},
                }
            )
        elif kind in ("install", "update") and not silent:
            handle_batch(req)


if __name__ == "__main__":
    main()
