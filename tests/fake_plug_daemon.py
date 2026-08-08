#!/usr/bin/env python3
"""Scripted simpleplug daemon for the install/update batch tests.

The real daemon is the wrong tool here: these tests are about what the Vim
side does with a batch's events, so they need those events to be exactly
reproducible — a named plugin that fails, another that is frozen, a checkout
that appears on disk — without a network, a git server or a clock.

Requests answered
  {"type":"ping","id":N}                    -> pong (protocol 2, real caps)
  {"type":"install"|"update","id":N,...}    -> progress per plugin, then done
  {"type":"check","id":N,...}               -> one check_result for the batch

An `update` also emits one `update_detail` per plugin it reports as updated,
with the full OIDs and commit subjects :PlugDiff renders and its rollback
pins.  The OIDs are derived from the plugin name so a test can predict them.

Environment
  FAKE_PLUG_FAIL      comma-separated plugin names to report as errors
  FAKE_PLUG_FROZEN    comma-separated plugin names to report as skipped/frozen
  FAKE_PLUG_BEHIND    comma-separated plugin names a check reports as behind
  FAKE_PLUG_DROP_CAPS comma-separated capability names to withhold from the
                      handshake, so a test can act out an un-rebuilt daemon
  FAKE_PLUG_SILENT    if set, answer the handshake and nothing else
  FAKE_PLUG_DELAY_MS  wait this long before the first progress event
  FAKE_PLUG_TERM_DELAY_MS
                      linger this long on SIGTERM before exiting, reading
                      nothing, so a test can hold the window in which
                      job_status() still says 'run' for a daemon that is on
                      its way out
  FAKE_PLUG_DUMP      append every request to this file, one JSON line each,
                      so a test can assert on what actually went over the wire

A plugin's checkout is materialised by copying `<dir>.src` to `<dir>` when that
template exists, which is how a test arranges for a plugin to become loadable
only once the "clone" reports success.
"""

import hashlib
import json
import os
import shutil
import signal
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
    "update_detail",
    "check",
]


def fake_oid(name, side):
    """A stable full-length OID for a plugin, so tests can assert on it."""
    return hashlib.sha1((name + "/" + side).encode("utf-8")).hexdigest()


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def names_from_env(key):
    return {n for n in os.environ.get(key, "").split(",") if n}


def ms_from_env(key):
    """Seconds from a millisecond env var.  Vim clears one by setting it to the
    empty string rather than removing it, so "" has to mean zero."""
    raw = os.environ.get(key, "").strip()
    return float(raw) / 1000.0 if raw else 0.0


def handle_batch(req):
    kind = req["type"]
    rid = req.get("id", 0)
    failing = names_from_env("FAKE_PLUG_FAIL")
    frozen = names_from_env("FAKE_PLUG_FROZEN")
    delay = ms_from_env("FAKE_PLUG_DELAY_MS")
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
        if status == "updated":
            emit(
                {
                    "type": "update_detail",
                    "id": rid,
                    "name": name,
                    "from": fake_oid(name, "from"),
                    "to": fake_oid(name, "to"),
                    "subjects": ["1111111 " + name + " newer", "0000000 " + name + " older"],
                }
            )
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


def handle_check(req):
    rid = req.get("id", 0)
    behind = names_from_env("FAKE_PLUG_BEHIND")
    frozen = names_from_env("FAKE_PLUG_FROZEN")
    items = []
    for plugin in req.get("plugins", []):
        name = plugin["name"]
        if name in frozen:
            items.append({
                "name": name, "state": "frozen", "behind": 0,
                "dirty": False, "subjects": [], "message": "frozen",
            })
        elif name in behind:
            items.append({
                "name": name, "state": "behind", "behind": 2, "dirty": False,
                "subjects": ["2222222 " + name + " incoming"],
                "message": "2 new on main",
            })
        else:
            items.append({
                "name": name, "state": "current", "behind": 0,
                "dirty": False, "subjects": [], "message": "up to date on main",
            })
    items.sort(key=lambda item: item["name"])
    emit({"type": "check_result", "id": rid, "items": items})


def install_slow_term():
    """Stay alive, and deaf, for a while after SIGTERM.

    job_stop() only sends SIGTERM, so between it and the process actually
    being reaped job_status() keeps answering 'run'.  A request sent in that
    window lands in the stdin pipe of a process that will never read it.
    """
    delay = ms_from_env("FAKE_PLUG_TERM_DELAY_MS")
    if not delay:
        return

    def linger(_signum, _frame):
        time.sleep(delay)
        os._exit(0)

    signal.signal(signal.SIGTERM, linger)


def main():
    install_slow_term()
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
                    "capabilities": {
                        c: True
                        for c in CAPABILITIES
                        if c not in names_from_env("FAKE_PLUG_DROP_CAPS")
                    },
                }
            )
        elif kind in ("install", "update") and not silent:
            handle_batch(req)
        elif kind == "check" and not silent:
            handle_check(req)


if __name__ == "__main__":
    main()
