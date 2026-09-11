# FlowPeek, for Sublime Text.        https://github.com/FlowPeek/flowpeek
# flowpeek-version: 1
#
# Sublime draws its own text and puts none of it in the macOS accessibility tree, so FlowPeek
# cannot see a diagram in this editor the way it sees one in a terminal. This file is the way in.
# It answers one question and only when asked: what Mermaid is on screen, and where is it.
#
# It writes nothing anywhere else, opens no socket, and makes no network request. While FlowPeek
# is not asking, the only thing it does is check once a second whether a file exists.
#
# FlowPeek put this here, and can take it away again: Settings -> Integrations -> Sublime Text.
# Deleting it by hand is just as good; nothing else in Sublime depends on it.

import json
import os
import time

import sublime
import sublime_plugin

VERSION = 1

# Both sides of the conversation live in one directory FlowPeek owns. A file rather than a socket:
# nothing to listen on, nothing to reach from off this machine, and nothing left running when
# FlowPeek is not.
HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, "Library", "Application Support", "FlowPeek", "sublime")
ASK = os.path.join(ROOT, "ask")
ANSWER = os.path.join(ROOT, "answer.json")

# How often to look for the question. A stat of one path, and nothing else, when nobody is asking.
IDLE_SECONDS = 1.0
# Once FlowPeek has asked, it is watching something the user is scrolling, so the answer has to keep
# up with them.
BUSY_SECONDS = 0.2
# An ask older than this is a FlowPeek that went away without cleaning up.
ASK_LIFETIME = 5.0

# What counts as a diagram to frame. Scope selectors rather than string matching, so a fenced block
# is found the way Sublime itself understands the file.
FENCE_SELECTORS = (
    "markup.raw.code-fence.mermaid",
    "markup.raw.block.fenced",
    "meta.code-fence",
)
FENCE_OPENERS = ("```mermaid", "~~~mermaid")


def _regions(view):
    """Every fenced block in the visible part of the view, as (begin, end) in buffer coordinates."""
    visible = view.visible_region()
    found = []
    for selector in FENCE_SELECTORS:
        for region in view.find_by_selector(selector):
            if region.intersects(visible) and (region.begin(), region.end()) not in found:
                found.append((region.begin(), region.end()))
        if found:
            break
    if found:
        return found
    # A syntax that does not scope its fences, or a plain-text buffer. Fall back to the fence line
    # itself, still only within what is on screen.
    text = view.substr(visible)
    offset = visible.begin()
    lowered = text.lower()
    cursor = 0
    while True:
        opener = -1
        for marker in FENCE_OPENERS:
            at = lowered.find(marker, cursor)
            if at >= 0 and (opener < 0 or at < opener):
                opener = at
        if opener < 0:
            break
        closer = lowered.find(marker[:3], opener + len(marker))
        end = len(text) if closer < 0 else closer + 3
        found.append((offset + opener, offset + end))
        cursor = end
    return found


def _report():
    window = sublime.active_window()
    view = window.active_view() if window else None
    if view is None or view.is_loading():
        return {"version": VERSION, "ok": False, "reason": "no view"}

    visible = view.visible_region()
    blocks = []
    for begin, end in _regions(view):
        # Clamped to what is on screen: a block running off the top has no top edge to draw.
        top_left = view.text_to_window(max(begin, visible.begin()))
        bottom_left = view.text_to_window(min(end, visible.end()))
        blocks.append({
            "range": [begin, end],
            "clipped": begin < visible.begin() or end > visible.end(),
            # Window coordinates, in device independent pixels. Sublime's API has no screen space;
            # FlowPeek adds the window origin, which it reads without needing any permission.
            "x": top_left[0],
            "top": top_left[1],
            "bottom": bottom_left[1] + view.line_height(),
            "text": view.substr(sublime.Region(begin, end)),
        })

    return {
        "version": VERSION,
        "ok": True,
        "at": time.time(),
        "view_id": view.id(),
        "line_height": view.line_height(),
        "em_width": view.em_width(),
        "viewport": list(view.viewport_extent()),
        "visible_range": [visible.begin(), visible.end()],
        "blocks": blocks,
    }


def _asked():
    try:
        return time.time() - os.path.getmtime(ASK) < ASK_LIFETIME
    except OSError:
        return False


def _write(report):
    try:
        os.makedirs(ROOT, exist_ok=True)
        # Written beside the answer and moved into place, so FlowPeek never reads half a file.
        temporary = ANSWER + ".partial"
        with open(temporary, "w") as handle:
            json.dump(report, handle)
        os.replace(temporary, ANSWER)
    except OSError:
        pass


_last = [None]


def _tick():
    if _asked():
        report = _report()
        # Only when something has actually moved. A reader who is reading is not producing events,
        # and rewriting the same answer twenty times a second would be work nobody asked for.
        signature = json.dumps(report.get("blocks")) + str(report.get("visible_range"))
        if signature != _last[0]:
            _last[0] = signature
            _write(report)
        sublime.set_timeout_async(_tick, int(BUSY_SECONDS * 1000))
    else:
        _last[0] = None
        sublime.set_timeout_async(_tick, int(IDLE_SECONDS * 1000))


def plugin_loaded():
    sublime.set_timeout_async(_tick, int(IDLE_SECONDS * 1000))


class FlowpeekReportCommand(sublime_plugin.TextCommand):
    """Answer once, now. What FlowPeek calls to check the plugin is really here."""

    def run(self, edit):
        _write(_report())
