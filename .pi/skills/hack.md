---
name: hack
description: Customize, build, and live-reload Poe with new features or themes on the fly
---

# Hack Poe with Privateer

Use this skill whenever the user asks to modify, restyle, or add features to Poe.

## Instructions

1. **Understand the Goal**: Identify what the user wants to change (e.g. theme colors, new UI widget, hotkey, editor behavior, word count).
2. **Review Relevant Code**:
   - Palette & visual design: `Sources/Poe/Theme.swift`
   - Layout & views: `Sources/Poe/Views/` (`EditorView.swift`, `SidebarView.swift`, `RootView.swift`, `AuroraBackground.swift`)
   - Text editing & AppKit: `Sources/Poe/Views/PoeTextView.swift`
   - Data & persistence: `Sources/Poe/Model/NoteStore.swift`
3. **Make Surgical Edits**: Use `edit` or `write` to update the files cleanly.
4. **Compile & Verify**:
   - Run `swift build` via bash to confirm zero build errors.
   - If there are compiler errors or warnings, resolve them immediately.
5. **Rebuild & Relaunch**:
   - Run `./build.sh --run` to compile the release binary, package `build/Poe.app`, and relaunch it on the user's screen.
6. **Report**: Summarize what was changed and invite the user to inspect their live Poe window.
