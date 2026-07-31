# NoteM

A native macOS notes app that keeps your notes as plain files you own — one folder
per note, markdown inside, no database and no account.

Built with SwiftUI and AppKit. Rich text editing, on-device semantic search, live
dictation, drawing, and a one-way bridge into an Obsidian vault.

> Interface language: Polish and English, switchable at runtime.

---

## Why another notes app

Most notes apps put your writing in an opaque database and ask you to trust a sync
service. NoteM stores every note as a folder on disk:

```
~/Documents/NoteM/
├── Praca/
│   └── 2026-07-31_10-14-22/
│       ├── note.md          ← plain markdown, readable by anything
│       ├── note.rich        ← full-fidelity formatting (colours, fonts, images)
│       ├── meta.json        ← title, tags, dates, links
│       └── attachments/     ← images and files you dropped in
├── .trash/                  ← soft-deleted notes, auto-purged after N days
└── .history/                ← up to 20 snapshots per note
```

Delete the app and your notes are still there, in a format you can read with
`cat`, grep through, back up, or open in any markdown editor.

---

## Features

### Writing

- **Rich text editor** — WYSIWYG on top of markdown. Headings, bold/italic,
  checklists, ordered and unordered lists, inline code, colours and fonts.
- **Two storage formats, one note.** `note.md` keeps the text portable for tools
  and scripts; `note.rich` preserves everything the markdown can't express
  (colours, pasted formatting, inline images) and is what the editor displays.
- **Paste sanitizer** — pasting from a browser brings the formatting you want
  without dragging in the web page's styling.
- **Drawing canvas** — sketch inside a note; the drawing lands as an attachment.
- **Live dictation** — click the mic and the recognized text appears in the note
  as you speak. Fully on-device (`SpeechTranscriber`, falling back to
  `SFSpeechRecognizer`), no audio file is written, and Polish is supported.
- **Spell checking and autocorrect** — follows the interface language.
- **Black or white note background**, remembered across notes and launches.
- **Autosave** one second after you stop typing, with the previous version kept
  as a history snapshot.

### Organising

- **Categories are just folders.** A note's category is the folder it sits in —
  visible in Finder, not an abstraction.
- **Filing rules** — "a note containing *invoice* goes to `Finance/{date}`".
  First matching rule wins; drag to reorder. Only unfiled notes are moved, so
  editing an already-filed note never makes it hop folders.
- **Tags** with autocomplete from tags already in use.
- **Wiki links** — type `[[Another note]]` to link notes together. Each note
  shows its **backlinks** ("what links here") under the editor.
- **Smart folders** — saved queries. Two built in (Today, Pinned), and you can
  define your own from conditions.
- **Pinning** keeps notes at the top of the list.
- **Task lists** — flag a note as a task list and it appears in the Tasks view
  with a badge counting what's still open.
- **Cover colours** per category, from a ten-theme palette.

### Finding

- **Exact search** across titles, tags and note bodies.
- **Semantic search** — switch the toggle to *By meaning* and NoteM finds notes
  about the same thing even when they don't contain your words. Runs on-device
  via `NLContextualEmbedding` (Apple's multilingual model, so Polish works too).
  Vectors are cached and recomputed only for notes whose content changed.
- **Command palette (⌘K)** — jump to any note by fuzzy title match, or run any
  command without touching the menu bar.
- **Quick capture** — a hot corner of the screen or ⌥⌘N opens a floating capture
  panel from anywhere, without bringing the main window forward. New notes made
  this way still go through the normal filing rules.
- **Attachments view** — every image, file and web link across all notes in one
  list.

### Sync and safety

- **iCloud Drive sync** — notes live in your iCloud Drive as an ordinary folder.
  Changes made on another Mac are detected within about seven seconds.
- **Conflict resolver** — when the same note was edited on two Macs offline, both
  versions are shown side by side and you choose which to keep. Nothing is
  silently discarded.
- **Unsaved work is protected** — an incoming sync reload is deferred while the
  editor still holds text that hasn't reached the disk.
- **Trash** with a configurable retention window, restoring to the original
  folder.
- **Version history** — up to 20 snapshots of every note.
- **Failed writes are reported.** If a save doesn't reach the disk, the app says
  so instead of showing you a note it didn't store.

### Export

- **Obsidian bridge** — mirrors notes into an Obsidian vault as plain `.md` files
  with YAML front matter, attachments included and links rewritten to Obsidian's
  embed syntax. Strictly one-way: NoteM overwrites only files it created itself
  (identified by a `notem-id` in the front matter) and never touches a note you
  wrote in Obsidian.
- **HTML** — a single self-contained page with images inlined as data URIs.
- **PDF** and **print**, with proper margins and pagination.

### Interface

- Polish and English, switched at runtime without a restart.
- Ten accent themes.
- Three layouts for the start page: sections, columns, or macOS-style stacks.

---

## Privacy

NoteM makes **no network connections**. There is no telemetry, no analytics, no
account and no server. Dictation and semantic search both run on-device. Your
notes go to your disk and — only if you turn sync on — to your own iCloud Drive.

---

## Requirements

- macOS 26 or later
- Xcode 26 or later to build

Live dictation uses the newer `SpeechTranscriber` where the system provides it and
falls back to `SFSpeechRecognizer` otherwise, so it works across the supported
range. Semantic search quietly disables itself if the on-device embedding model
isn't available.

## Building

```bash
git clone https://github.com/mikagosz/NoteM.git
cd NoteM
open NoteM.xcodeproj
```

Then press ⌘R.

The project ships with a pinned local code-signing identity, which won't exist in
your keychain. Set **Signing & Capabilities → Signing Certificate** to *Sign to
Run Locally*, or point it at your own certificate.

> **Why a pinned certificate?** macOS ties permissions such as Accessibility to an
> app's code signature. With the default ad-hoc signature that identity changes on
> every rebuild, so the system treats each build as a new app and asks for
> permission again, forever. Signing with a stable certificate — even a self-signed
> one you make yourself in Keychain Access — fixes it.

## Tests

```bash
xcodebuild -project NoteM.xcodeproj -scheme NoteM -destination 'platform=macOS' test
```

53 tests covering the storage layer, the Obsidian export and the filing engine —
the three places where a bug costs you data rather than pixels.

## Project layout

| Area | Files |
|---|---|
| Storage | `NoteStore.swift`, `Note.swift`, `NotesModel.swift` |
| Editor | `RichTextEditor.swift`, `MarkdownStyler.swift`, `EditorToolbar.swift`, `PasteSanitizer.swift` |
| Views | `ContentView.swift`, `NoteDetailView.swift` |
| Organising | `Categorization.swift`, `SmartFolder.swift`, `Attachment.swift` |
| Search | `SemanticIndex.swift`, `CommandPalette.swift` |
| Input | `VoiceNotes.swift`, `DrawingEditor.swift`, `QuickCapture.swift` |
| Export | `ObsidianExport.swift`, `HTMLExport.swift` |
| Sync | `Sync.swift` |
| Misc | `Theme.swift`, `Localization.swift` |

## Licence

MIT — see [LICENSE](LICENSE).
