# Teaching FlowPeek to read your app

FlowPeek draws the Mermaid diagram that is already on somebody's screen. It reads most applications
through the macOS Accessibility API, and some applications cannot be read that way at all: if your
app draws its own text — a custom toolkit, a canvas, a GPU renderer — then there is nothing under
the pointer for anyone to find, and FlowPeek can do nothing in your window.

This document is the way out of that. Write three small files and FlowPeek will frame the diagrams
in your window as if it could see them, because you are telling it where they are.

You do not need to ask us, register anywhere, or ship anything through us. FlowPeek watches every
provider it finds. It does not have a list of approved applications and there is nothing to be added
to.

The one person who can say no is the reader. Every provider found here is listed in FlowPeek's
settings, under Integrations — the ones FlowPeek did not write under *Also registered here* — each
with a switch beside it, named by the `name` in your manifest. That tab re-reads the directory every
time it is opened, so a provider that registered after FlowPeek launched is in the list the next
time somebody looks, without a relaunch. Switched off, FlowPeek stops writing `ask` and deletes the
one it had already written, never reads your answers, and leaves your files exactly where you put
them — they are yours, not ours to delete. So a provider that stops being asked has not failed;
somebody has decided, and the right response is the idle loop you would run anyway.

## What you are agreeing to do

Answer one question, only while it is being asked: **which Mermaid blocks are visible in your
window, and where are they?**

That is the whole protocol. You are not being asked for the document, for the caret, for anything
the user has not got on screen, or for anything at all when FlowPeek is not looking.

## Where

```
~/Library/Application Support/FlowPeek/integrations/<your id>/
├── integration.json   you write once
├── ask               FlowPeek writes; you read
└── answer.json       you write; FlowPeek reads
```

`<your id>` is yours to choose. Use something nobody else will: a reverse-DNS name is ideal, and the
directory name and the `id` in the manifest must be the same string or the provider is ignored.

## 1. Register: `integration.json`

Write it once, when your plugin or app first runs. The file appearing is the whole of registration.

```json
{
  "version": 1,
  "id": "com.example.editor",
  "name": "Example Editor",
  "bundleIdentifiers": ["com.example.editor"]
}
```

| Field | Meaning |
| --- | --- |
| `version` | The protocol version. `1` today. A manifest naming a version FlowPeek does not know is ignored rather than guessed at. |
| `id` | Must equal the directory name. |
| `name` | Shown to the reader; a product name, not a translation. |
| `bundleIdentifiers` | Which application you speak for. FlowPeek measures your answers against the frontmost window of a process with one of these, so getting this wrong means rectangles in the wrong place. List more than one if your product has had more than one identifier. |

Delete the directory to stop being watched.

## 2. Listen: `ask`

FlowPeek touches `ask` while it wants answers and deletes it when it stops. **Its modification date
is the question.** There is no content.

- Newer than five seconds: FlowPeek is watching. Answer when the picture changes.
- Older, or absent: FlowPeek is not there — it has quit, the reader is in another application, or
  they have switched you off in settings. All three mean the same thing to you: write nothing and go
  back to idle.

Poll for it as cheaply as you can — one `stat` a second is plenty, and that is all the reference
implementation does when nobody is asking. Do not keep a busy loop running for a question that is
not being asked.

## 3. Answer: `answer.json`

Write it when the visible picture changes, and only while `ask` is fresh. A window that is only
moved is not a change: FlowPeek measures your last answer against the window's new frame itself, so
the frame follows a drag without you writing anything. Write it atomically: to a temporary file in
the same directory, then rename over the target. FlowPeek reads whole files and must never see half
of one.

```json
{
  "version": 1,
  "ok": true,
  "at": 1789123456.78,
  "line_height": 15.0,
  "em_width": 7.0,
  "blocks": [
    {
      "range": [0, 78],
      "clipped": false,
      "clipped_top": false,
      "clipped_bottom": false,
      "x": 56.0,
      "top": 34.0,
      "bottom": 124.0,
      "text": "```mermaid\nflowchart TD\n    A --> B\n```"
    }
  ]
}
```

| Field | Meaning |
| --- | --- |
| `version` | `1`. An answer from a newer protocol is left alone. |
| `ok` | `false` when you have nothing to say — no window, a document still loading. Everything else may be omitted. |
| `at` | Unix seconds, when you wrote it. FlowPeek ignores an answer more than six seconds old, so it does not draw a frame around where a diagram used to be. It may be left out, but then nothing distinguishes a current answer from an abandoned one, so send it. |
| `line_height`, `em_width` | Optional, in points. Neither places anything. `line_height` is read in one case: when a `clipped` block did not name its cut edges, it sets how close to the viewport's own edge counts as having been clamped against it, because clamping lands on a line boundary. `em_width` is reported because it is cheap and it explains the geometry. |
| `content_inset_top` | Optional, in points. How far your content area sits below the top of your window frame. Leave it out unless the system would get it wrong; see below. |
| `blocks` | What is visible. An empty array is a perfectly good answer and means "nothing on screen". |

Keys FlowPeek does not know are ignored rather than refused. The reference implementation writes a
few of its own for debugging; they are no part of the protocol and cost nothing.

### A block

| Field | Meaning |
| --- | --- |
| `range` | `[begin, end]` in your own buffer coordinates. FlowPeek does not interpret these; they are yours, for your own debugging. |
| `clipped` | `true` if the block runs off the top or bottom of the viewport. FlowPeek frames it anyway, with the cut side left open, so a diagram taller than the window still gets an outline — that is the case where a preview is worth most. Clamp the coordinates to what you can see and set this. |
| `clipped_top`, `clipped_bottom` | Optional, and read only when both are there. Which edge ran off. Send both or neither: one on its own is ignored, and FlowPeek falls back to working the cut edges out from where your rectangle sits against the viewport, which is right but less certain than being told. When both are there they are taken as given — two `false`s frame the block closed whatever `clipped` says. |
| `x`, `top`, `bottom` | **Content-area coordinates, top-left origin, in points.** Not screen coordinates — you do not know where your window is, and FlowPeek does. `top` is the top of the block's first line; `bottom` is the bottom of its last, so `bottom - top` is the block's height. Clamp `top` and `bottom` to your viewport when the block runs past it, but never `x`: the left edge is the block's own, and taking it from the first visible character instead moves the frame out to the window's edge whenever the diagram is scrolled. |
| `text` | The Mermaid source, fences included or not. FlowPeek decides for itself whether this is a diagram; send what is between the fences and it will be fine. Text that carries on past its own closing fence is dropped rather than framed: that is a range that overran its block, and the frame it would draw is one around the rest of the document. |

FlowPeek draws the frame from `x` to a little short of the window's right edge. You do not report a
width: most text APIs cannot say where a rendered line ends, and a frame that stops in the middle of
a line looks broken.

### Coordinates, precisely

`x` and `top` are offsets from the **top-left of your window's content area** — below the title bar,
which is what almost every toolkit already hands you. Report what your own API gives you and do not
add anything for the chrome: FlowPeek asks macOS how tall a titled window's title bar is and adds
that itself. It is 32 points on current macOS and was 28 before, which is exactly the sort of number
you should not have to carry.

If your window has no title bar, or has chrome the system would not predict, say so with
`content_inset_top` in the answer:

```json
{"version": 1, "ok": true, "content_inset_top": 0.0, "blocks": [ ... ]}
```

A quick way to check your numbers: draw a one-pixel rectangle in your own window at the coordinates
you are about to report, take a screenshot, and see whether it lands on the block. Then look at
FlowPeek's frame and see whether it lands in the same place. That is how the reference
implementation was verified, and how a 32-point error in it was found.

## What FlowPeek does with it

A faint frame around each block, in the reader's chosen colour, the same one the terminal watch
draws. A block you marked `clipped` is framed with its cut sides open — no line along the edge the
diagram runs past, and the sides fading out as they reach it — so send the whole block's `text` even
when only part of it is on screen. What opens is the diagram, not the visible half of it. Bring the pointer near and that frame brightens; hold Option and click, and the diagram opens
in a preview panel. Nothing is drawn while your application is not frontmost, and nothing is drawn
while a preview is already covering the screen.

## What FlowPeek will not do

- Ask for anything but what is visible.
- Read `answer.json` when it did not write `ask`.
- Keep any of it. The source in an answer is treated exactly like a diagram found any other way: it
  is drawn, and it is written down only if the reader opens it and has history switched on.
- Send any of it anywhere. FlowPeek makes no network request while drawing a diagram at all.

## A reference implementation

`Sources/FlowPeek/Resources/flowpeek-sublime.py` is the whole of the Sublime Text provider, 249
lines of Python of which 160 are code, and it is the same contract as anybody else's. Read it as the
worked example. Note in particular:

- it polls once a second when nobody is asking, and five times a second when somebody is;
- it writes only when the answer actually changed, so a reader who is reading produces no writes;
- it finds fenced blocks through the editor's own syntax scopes before falling back to searching for
  the fence itself;
- it clamps a partly visible block, marks it `clipped`, and names both edges with `clipped_top` and
  `clipped_bottom`, while still sending the whole block's source;
- it maps buffer points to window coordinates through the editor's *layout* space rather than
  asking for a window position directly. Sublime answers `text_to_window` with `(0, 0)` for any
  point outside the viewport -- the x as well as the y -- so a block scrolled off the top reported
  its left edge as zero and the frame wrapped the whole window. If your toolkit does something
  similar, measure the offset from a point you can see and apply it to the point you cannot;
- it searches a window wider than the viewport, so a diagram taller than the window -- which has
  neither of its fences on screen -- is still found whole.

## Versioning

The protocol version is `1`. If it changes, FlowPeek will keep reading version 1 answers for as long
as anybody is writing them: a provider you shipped is a provider somebody is running, and breaking
it silently is not on the table. Watch this file, and the release notes.

## Questions

Open an issue at <https://github.com/FlowPeek/flowpeek/issues>. If you have written a provider, say
so and we will link it here.
