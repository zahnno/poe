# AGENTS.md — Agent & Hacker Guide for Poe

Poe is a native, minimalist macOS notepad built in pure Swift with zero external dependencies. It is designed to be self-contained, fast to compile, and easy to modify on the fly with local AI agents (such as Privateer `pi`, Claude Code, Cursor, Aider).

---

## ⚡ Quick Start for AI Agents

When customizing or extending Poe:
1. **Locate the target files** (see architecture map below).
2. **Make minimal, surgical changes** in Swift/SwiftUI.
3. **Verify compilation**: `swift build`
4. **Build and hot-relaunch**: `./build.sh --run`

> **Note**: User notes are stored in `~/Library/Application Support/Poe/notes.json` and linked files. Relaunching Poe does not destroy or lose user data.

---

## 📁 Architecture Map

```
Sources/Poe/
├── PoeApp.swift              # App entry point, menu commands, window definitions
├── Theme.swift               # Design system: colors, aurora gradients, fonts, glass effects
├── Model/
│   ├── Note.swift            # Note data structure (UUID, text, dates, linked file URL)
│   ├── NoteStore.swift       # Central state store, persistence, debounced writes, search
│   └── TextFile.swift        # Plain text & markdown file format detection / handling
└── Views/
    ├── RootView.swift        # Top-level window container, aurora backdrop, split view
    ├── SidebarView.swift     # Note list, search query box, item deletion
    ├── EditorView.swift      # Main editing pane, title header, accessories, preview toggle
    ├── PoeTextView.swift     # AppKit NSTextView wrapper (text layout, typing mechanics)
    ├── MarkdownPreview.swift # Rich rendered markdown view
    ├── MarkdownStyle.swift   # Visual styles for headings, quotes, code blocks
    ├── AuroraBackground.swift# Animated ambient background gradient
    └── FindBar.swift         # In-buffer search bar UI
```

---

## 🎨 Common Customization Points

| What to change | Primary file | Notes |
|---|---|---|
| **Theme / Colors** | `Sources/Poe/Theme.swift` | Modify background, accents, font sizes, glass opacity |
| **Aurora Glow** | `Sources/Poe/Views/AuroraBackground.swift` | Ambient animated background mesh |
| **Editor Chrome / Badges** | `Sources/Poe/Views/EditorView.swift` | Add status badges (word count, reading time, stats) |
| **Sidebar & Note List** | `Sources/Poe/Views/SidebarView.swift` | Change note preview formatting, sorting, metadata |
| **Keyboard Shortcuts** | `Sources/Poe/PoeApp.swift` | Add or remap macOS menu bar shortcuts |
| **Data & Storage** | `Sources/Poe/Model/NoteStore.swift` | Persistence, export behaviors, note syncing |

---

## 🛠 Build & Test Commands

* **Compile (fast check)**:
  ```bash
  swift build
  ```
* **Assemble & Relaunch App**:
  ```bash
  ./build.sh --run
  ```
* **Install to `/Applications`**:
  ```bash
  cp -R build/Poe.app /Applications/
  ```

---

## 🔒 Agent Rules

1. **Zero Dependencies**: Keep Poe dependency-free. Do not add SPM packages unless explicitly instructed.
2. **Always Verify**: Run `swift build` after editing to ensure there are no compilation errors.
3. **Preserve Editor Responsiveness**: Avoid heavy synchronous calculations on the main thread during typing.
