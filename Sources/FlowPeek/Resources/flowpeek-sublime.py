# FlowPeek, for Sublime Text.        https://github.com/FlowPeek/flowpeek
# flowpeek-version: 6
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
ROOT = os.path.join(HOME, "Library", "Application Support", "FlowPeek", "integrations", "sublime-text")
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

# How far outside the viewport to look for a fence, in characters, when the syntax does not scope
# its code blocks. The visible text alone is the wrong window to search: a diagram taller than the
# window has neither of its fences on screen, and one scrolled half off has only the closing one.
# Roughly a hundred rows each way, which is the same margin FlowPeek reads a terminal with.
SEARCH_MARGIN = 8000


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
    # itself, searched in a window wider than the viewport so a block whose fences are both off
    # screen is still found whole.
    window = sublime.Region(
        max(0, visible.begin() - SEARCH_MARGIN),
        min(view.size(), visible.end() + SEARCH_MARGIN),
    )
    text = view.substr(window)
    offset = window.begin()
    lowered = text.lower()
    cursor = 0
    while True:
        opener = -1
        opened_with = None
        for candidate in FENCE_OPENERS:
            at = lowered.find(candidate, cursor)
            if at >= 0 and (opener < 0 or at < opener):
                opener, opened_with = at, candidate
        if opener < 0:
            break
        # Closed by the marker that opened this block, not by whichever one the loop above happened
        # to leave behind. That bug looked for "~~~" to close a "```" block, never found one, and
        # ran the block to the end of the search window: scrolled past a diagram, with the block
        # entirely off the top of the screen, the frame was drawn over the whole window.
        closer = lowered.find(opened_with[:3], opener + len(opened_with))
        end = len(text) if closer < 0 else closer + 3
        begin_at, end_at = offset + opener, offset + end
        # Widening the search means blocks entirely off screen turn up too. Only the ones with some
        # of themselves in the viewport are FlowPeek's business.
        if end_at >= visible.begin() and begin_at <= visible.end():
            found.append((begin_at, end_at))
        cursor = end
    return found


def _window_mapping(view, visible):
    """How to turn any buffer point into window coordinates, including points off the screen.

    Sublime answers `text_to_window` with (0.0, 0.0) for a point outside the viewport -- measured,
    not documented, and it does it for the x as well as the y. Asking it about a block that starts
    above the screen therefore reported the left edge as zero, and the frame jumped from the fence's
    indent out to the window's edge. Layout coordinates do not move with the scroll and are answered
    for every point in the buffer, so the offset between the two is measured once, here, from a
    point in the middle of what is on screen, and applied to the block's own start.
    """
    viewport = view.viewport_position()
    probe = (visible.begin() + visible.end()) // 2
    window = view.text_to_window(probe)
    layout = view.text_to_layout(probe)
    if window == (0.0, 0.0) and layout != (0.0, 0.0):
        return None
    return (
        viewport,
        window[0] - (layout[0] - viewport[0]),
        window[1] - (layout[1] - viewport[1]),
    )


def _report():
    window = sublime.active_window()
    view = window.active_view() if window else None
    if view is None or view.is_loading():
        return {"version": VERSION, "ok": False, "reason": "no view"}

    visible = view.visible_region()
    mapping = _window_mapping(view, visible)
    if mapping is None:
        return {"version": VERSION, "ok": False, "reason": "no mapping"}
    viewport, offset_x, offset_y = mapping
    extent = view.viewport_extent()
    # The text area's own top and bottom in window coordinates. offset_y is the tab bar: measured at
    # 34 points on a window with one tab, which is why the block's edges are clamped to this rather
    # than to zero. Clamping to zero drew the frame up over the tabs.
    top_limit = offset_y
    bottom_limit = offset_y + extent[1]

    def to_window(point):
        layout = view.text_to_layout(point)
        return (layout[0] - viewport[0] + offset_x, layout[1] - viewport[1] + offset_y)

    blocks = []
    for begin, end in _regions(view):
        start = to_window(begin)
        # The *last character of the block*, not the one after it. A fenced region ends at the
        # offset following its closing fence, which is the start of the next line, and measuring
        # there put the frame's bottom edge one whole line below the diagram.
        finish = to_window(max(begin, end - 1))[1] + view.line_height()
        top = max(start[1], top_limit)
        bottom = min(finish, bottom_limit)
        if bottom <= top:
            continue
        above = start[1] < top_limit - 0.5
        below = finish > bottom_limit + 0.5
        blocks.append({
            "range": [begin, end],
            "clipped": above or below,
            # Which edge ran off, so FlowPeek can draw the frame with that side left open instead
            # of closing it at the viewport and claiming the diagram ends there.
            "clipped_top": above,
            "clipped_bottom": below,
            # Content-area coordinates, in device independent pixels. The x is the block's own,
            # never the first visible character's: a diagram scrolled half off the top keeps its
            # left edge where the fence is. Nothing is added for the title bar on purpose --
            # FlowPeek asks macOS how tall one is, and that number has moved between releases.
            "x": start[0],
            "top": top,
            "bottom": bottom,
            "text": view.substr(sublime.Region(begin, end)),
        })

    return {
        "version": VERSION,
        "ok": True,
        "at": time.time(),
        "view_id": view.id(),
        "line_height": view.line_height(),
        "em_width": view.em_width(),
        "viewport": list(extent),
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
# Whether this module is still the one Sublime is running.
#
# Replacing the file reloads it, but the timeout the previous module already queued keeps firing,
# and each tick queues the next one -- so an old copy answers forever, alongside the new one. Two
# versions writing the same file is worse than either of them alone: FlowPeek reads whichever wrote
# last, and an update appears to half take. Sublime calls plugin_unloaded on the module it is
# replacing, which is where this is switched off.
_alive = [True]


def plugin_unloaded():
    _alive[0] = False


def _tick():
    if not _alive[0]:
        return
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
