# Poe

A quiet place to think — a native macOS notepad. Dark, glassy, keyboard-first,
and it saves itself. It opens your files too: Markdown, plain text, code, or
anything else made of text, edited in place.

<p><img src="assets/icon.png" width="120" alt="Poe icon"></p>

![Poe](assets/screenshot.png)

## Build

```bash
./build.sh
open build/Poe.app
```

Requires Xcode 15 / Swift 5.9 and macOS 13 or later. No dependencies — SwiftUI,
AppKit, and Core Graphics only. `build.sh` compiles the executable, draws the
lantern icon from `tools/make_icon.swift`, assembles `build/Poe.app`, and
ad-hoc signs it.

To install: `cp -R build/Poe.app /Applications/`

## Shortcuts

| | |
|---|---|
| `⌘N` | New note |
| `⌘O` | Open a file |
| `⌘F` | Search every note |
| `⌘P` | Toggle markdown preview |
| `⌘D` | Pin / unpin |
| `⇧⌘D` | Duplicate |
| `⌘0` | Toggle sidebar (focus mode) |
| `⌥⌘↑` / `⌥⌘↓` | Previous / next note |
| `⌘⌫` | Delete note (asks first, unless empty) |
| `⌘S` | Save now |
| `⇧⌘S` | Save as… (and edit there from then on) |
| `⌘R` | Reload the open file from disk |
| `⇧⌘R` | Reveal the open file in Finder |

## Opening files

Poe opens a file three ways: `⌘O`, dragging it onto the window, or double-clicking
it in Finder (`open -a Poe notes.md` works too — Poe registers as an editor for
Markdown, plain text, source code, and structured text like JSON and YAML).

An opened file becomes a note that is *tethered* to it. It shows up in the
sidebar with its extension on a chip, it is searchable alongside everything else,
and every keystroke goes back to the file on disk — in the encoding and line
endings it arrived with, so a Latin-1 file with CRLF newlines stays exactly that.
Change the file in another editor and Poe picks the change up when it comes back
to the front. **Note → Stop Editing File** keeps the text and drops the tether;
deleting the note leaves the file alone.

Anything that isn't text is refused with a reason, as is anything over 8 MB.

Markdown and plain text are **styled as you write**: headings grow, `**bold**`,
`*italic*`, `` `code` ``, quotes, lists, task boxes and links all take hold, and
the syntax that produces them dims rather than disappearing — the buffer stays
exactly the text on disk. A `.md` file opens in the rendered preview; `⌘P` (or
the pencil) switches to editing. Code and data files get tighter line spacing
and no styling or spell-check. Styling is scoped to what's on screen, and stands
down entirely past 60 KB, where `⌘P` still renders the whole document.

## Where notes live

`~/Library/Application Support/Poe/notes.json` — one plain JSON document,
written atomically, debounced to at most one write per 0.7s of typing.
**Note → Poe Notes Folder** opens it in Finder.

## Layout

```
Sources/Poe/
  PoeApp.swift          App entry, menu-bar commands, window styling
  Theme.swift           Colours, glass panel, relative dates
  Model/Note.swift      A note, plus derived title/snippet/word count
  Model/TextFile.swift  Reading and writing files without changing them
  Model/NoteStore.swift The library: persistence, selection, commands, files
  Views/RootView.swift  Sidebar + editor layout
  Views/SidebarView.swift
  Views/EditorView.swift
  Views/PoeTextView.swift    NSTextView wrapper (caret glow, line spacing, undo)
  Views/MarkdownStyle.swift  Live markdown styling — attributes only, never text
  Views/MarkdownPreview.swift
  Views/LanternMark.swift    The lantern logo, drawn in Canvas
  Views/AuroraBackground.swift
  DebugSnapshot.swift   Dev-only smoke test (see below)
tools/make_icon.swift   Draws the app icon at every size
tools/file_tests/       Headless checks for the file layer (see below)
```

## Smoke test

The app can drive itself and screenshot the result — useful because Screen
Recording permission is not needed to capture your own window:

```bash
POE_SELFTEST=1 POE_SNAPSHOT=/tmp/poe .build/release/Poe
```

It types a note, flips to preview, creates a second note, enters focus mode,
writes `/tmp/poe-*.png` at each step, prints the model state, and quits.
Without `POE_SELFTEST` it just captures one screenshot and exits.

`POE_SELFTEST=file` runs the file story instead — open, edit, save back, reopen,
adopt a change made outside Poe, refuse a binary, survive the file being deleted —
and prints a pass/fail line per check:

```bash
cp somewhere/notes.md /tmp/case.md
POE_SELFTEST=file POE_SNAPSHOT=/tmp/poe POE_OPEN=/tmp/case.md .build/release/Poe
```

It rewrites the file it is given, so hand it a copy. The parts that need no
window run without one:

```bash
swiftc Sources/Poe/Model/TextFile.swift Sources/Poe/Model/Note.swift \
       tools/file_tests/main.swift -o /tmp/poe-file-tests && /tmp/poe-file-tests
```

## Notes on the design

- The editor is an `NSTextView`, not `TextEditor`, so it can have a glowing
  caret, real line spacing, a text container inset, and proper undo.
- It stays mounted at all times; the markdown preview layers over it. Swapping
  them as `if/else` branches made SwiftUI rebuild the text view on every
  toggle — which lost undo history and dropped note switches on the floor.
- `NoteStore` is a singleton rather than an `@StateObject` on the `App`.
  Menu commands are built outside any view's lifetime, and SwiftUI hands them
  their own uninitialised copy of a `@StateObject` — every shortcut silently
  did nothing until this changed.
- The text is handed to `PoeTextView` by value, not as a `@Binding`. SwiftUI
  diffs a representable on its stored properties, and a binding's *contents* are
  invisible to that comparison — so text that changed anywhere but in the editor
  (a reload from disk, a file edited in another app) never reached the buffer
  until some unrelated redraw happened along.
- One text view serves every document, which means it carries things between
  them. Switching documents clears the undo stack, because undoing into a file
  would splice the previous note's words into it, and macOS autocorrection is
  off, because it rewrites text *asynchronously* — a correction queued against
  one document used to land in the next one, on disk.
- Files arrive through two doors. SwiftUI claims the open-documents event for a
  `WindowGroup` app and hands `application(_:open:)` an empty list, so
  `RootView.onOpenURL` catches most of them; the delegate still sees some.
  Opening a path already in the library re-selects it instead of cloning it.
- The markdown preview parses in `init` and lays out lazily. It used to re-split
  every line and build every view on each redraw, which is most of a second in a
  100 KB note — invisible until files could be opened and one of them was large.
- The aurora is four blurred orbs on `repeatForever` transform animations, so
  the compositor owns it and nothing spins the fans while you type.
