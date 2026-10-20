# Home window, Save As, matched text and conveniences: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A home window of recent files at launch, a visible Save As, text boxes that match the page's font, and a handful of conveniences. The build is installed to `/Applications/Folio.app`.

**Architecture:**
- Matching is a pure function over PDFKit's lines and their font and colour runs. Canvas uses it, and adds a text box to the document only when its typing ends.
- The home window is a SwiftUI `Window` scene beside the DocumentGroup, chosen at launch with `defaultLaunchBehavior`.
- The conveniences live where their input arrives: Canvas `keyDown`, a toolbar item, and the Tools menu.

**Tech Stack:** Swift 5 mode on macOS 26, using SwiftUI, AppKit, PDFKit and QuickLookThumbnailing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-20-home-save-as-matched-text-design.md`

## Global Constraints

- macOS 26, SwiftPM, `swift-tools-version:5.9`. No new packages.
- Every document change goes through `FolioDocument.change`, so it can be undone and has a name.
- Fallback text font: Helvetica 12, black.
- Commit after each task. Never push. The owner says when.
- Don't run `build.sh` or `swift build -c release` while the background DMG job is running. `swift test` uses `.build/debug` and is safe.

## Review Focus

1. **Launching by opening a PDF from Finder.** The document opens and the home window doesn't stay behind it. Checked at runtime in Task 4.
2. **Quitting with documents open.** The home window doesn't flash during the quit. On relaunch the documents come back and the home window doesn't. Checked at runtime in Task 4.
3. **Save As after autosave has already written changes into the original.** Check what the original file holds afterwards. If it holds the changes, add "Save As writes the changes to the new file only; the original keeps its last opened state" (or the system's actual behaviour) to the README and the spec. Checked at runtime in Task 5.
4. **Keys in a restricted or locked document.** The toolbar is disabled there, so a key mustn't pick a tool or nudge. Tested in Task 6.
5. **A click between two styles, such as a red Helvetica line under a Georgia line.** The box takes the nearer run and not the line's first font. Tested in Task 1.

---

### Task 1: Matched text boxes (pure)

**Files:**
- Modify: `Sources/Folio/Annotations.swift`. Add `textBox(at:on:)` and `fit(_:around:in:)` next to `coverLine`, and `setFont(_:of:)` in the `FolioDocument` extension.
- Modify: `Tests/FolioTests/DocumentTests.swift`. `makePDF` gains `styles: [Int: [NSAttributedString.Key: Any]] = [:]`: per-row attributes that replace Georgia 18 for that row.
- Test: `Tests/FolioTests/AnnotationTests.swift`

**Interfaces:**
- Produces:
  - `func textBox(at point: CGPoint, on page: PDFPage) -> PDFAnnotation`. The FreeText has empty contents, `color = .clear` and a 0-width border.
  - `func fit(_ bounds: CGRect, around text: String, in font: NSFont) -> CGRect`. It only grows, and keeps the top-left corner.
  - `FolioDocument.setFont(_ font: NSFont, of box: PDFAnnotation)`. One change named "Change Font": the font, plus `fit` of the bounds around `box.contents`.

- [ ] **Step 1: Write the failing tests**
  - `testTextBoxSitsOnTheLineItIsBeside`. Use page `makePDF([["Name:"]])`; the line is the `selectionForLine` at (90, 725). Click at (300, 725).
    - The font is Georgia 18 and `fontColor` is black.
    - `bounds.minY == line.minY - 2`.
    - `bounds.height == font.ascender - font.descender + 4` (accuracy 0.01).
    - `bounds.minX == 298`.
    - `contents ?? ""` is empty.
  - `testTextBoxTakesTheNearestRunAndItsColour`. Use page `makePDF([["Heading", "Small print"]], styles: [1: [.font: NSFont(name: "Helvetica-Bold", size: 11)!, .foregroundColor: NSColor.red]])`.
    - A click at (300, 682), near row 1 (y 680), gives Helvetica-Bold 11.
    - Its `fontColor`, converted to sRGB, has red > 0.9 and green < 0.1.
    - A click at (300, 728) gives Georgia 18.
  - `testTextBoxOnAPageWithNoText`. On `makePDF([[]])`, a click at (100, 100) gives Helvetica 12 in black, and `bounds.midY == 100` (accuracy 0.01).
  - `testFitOnlyGrowsFromTheTopLeft`. `fit(CGRect(x: 10, y: 100, width: 300, height: 40), around: "Hi", in: Helvetica 12)` is unchanged. Around a long string, width grows and `maxY` stays 140.
  - `testSetFontIsOneUndoableChange`. A box with contents "Hello" in Helvetica 12; `setFont` to Helvetica 30.
    - The font is 30 pt, the box grew, and `undoActionName == "Change Font"`.
    - After undo, the font and bounds are back.

- [ ] **Step 2: Run `swift test --filter AnnotationTests` and check that the new tests fail to compile**

- [ ] **Step 3: Implement**
  - Collect the runs. For each `selectionsByLine()` line of `page.selection(for: page.bounds(for: .mediaBox))`:
    - Take the line's `attributedString` and enumerate its attribute runs.
    - Map each run to the page's string by adding `line.range(at: 0, on: page).location`.
    - Measure each run with `page.selection(for:)` over that range, `.bounds(for: page)`.
    - Keep each run's line bounds too.
  - Pick the nearest run by the point's distance to the rect: `hypot` of how far it lies outside on each axis.
  - It's "beside" when `point.y` lies within the run's line bounds vertically. Then `y = lineBounds.minY - 2`, else `y = point.y - height / 2`.
  - Width starts at `font.pointSize`.
  - `fit` measures with `NSString.size(withAttributes:)`: `width + 8`, `height + 4`, the same as the existing `finishEditing`.

- [ ] **Step 4: Run `swift test` and check that all tests pass**

- [ ] **Step 5: Commit** with the message "Match a text box to the page's nearest text: its font, size, colour and line".

### Task 2: Typing into new boxes

**Files:**
- Modify: `Sources/Folio/Canvas.swift`. Change the `.text` and `.editText` cases of `mouseDown`, plus `edit`, `finishEditing` and `endedEditing`. Add a text-change observer in `init`.
- Test: `Tests/FolioTests/ViewerTests.swift`

**Interfaces:**
- Consumes: `textBox(at:on:)`, `fit(_:around:in:)` and `coverLine(at:on:)`.
- Produces:
  - `Canvas.edit(_ box: PDFAnnotation, on page: PDFPage, adding name: String? = nil)`. With a name, the box isn't on the page yet. `finishEditing` adds it under that name, but only if the text differs from `box.contents ?? ""`. That covers both cases: a text box left empty is never added, and a cover can be emptied to blank out its line.
  - `Canvas.finishEditing()`, now internal.
  - `private(set) var editor: (field: NSTextField, box: PDFAnnotation, page: PDFPage, adding: String?)?`

- [ ] **Step 1: Write the failing test `testNewTextBoxJoinsTheDocumentOnlyWithWords`**
  - Viewer on `makePDF([["Name:"]])` with `canvas.document` set and a `manualUndo`.
  - First: `edit(textBox(at: (300, 725), on: page), on: page, adding: "Add Text")`, then set `editor!.field.stringValue = "Jo"` and call `act(undo) { finishEditing() }`.
    - One annotation, with contents "Jo".
    - `undoActionName == "Add Text"`.
    - After undo, no annotations.
  - Second: an empty field, finished, adds nothing.
  - Third: a `coverLine` emptied and finished is added with contents "", under "Edit Text".

- [ ] **Step 2: Run `swift test --filter ViewerTests` and check that it fails to compile**

- [ ] **Step 3: Implement**
  - The editor field's background is the box's colour, so a cover is white and a text box is transparent. Add a 1 pt `controlAccentColor` layer border, so you can see where you type.
  - Each text change widens the field to its text: measure `currentEditor()?.string` in the field's font, + 12.
  - The Edit Text warning stays at the click. The `.text` click still switches the tool back to Select.

- [ ] **Step 4: Run `swift test` and check that all tests pass**

- [ ] **Step 5: Commit** with the message "Add a text box or cover only when its typing ends, as one undo step".

### Task 3: Fonts panel

**Files:**
- Modify: `Sources/Folio/Canvas.swift`. Add `showFonts()` and `@objc changeFont(_:)`. `selected.didSet` tells `NSFontManager` the selected box's font.
- Modify: `Sources/Folio/App.swift`. Tools › Show Fonts, ⌘T, disabled with no viewer.

**Interfaces:**
- Consumes: `FolioDocument.setFont(_:of:)`.

- [ ] **Step 1: Implement**
  - `changeFont(_ sender: NSFontManager?)` acts only on a selected `FreeText`, with `sender.convert(box.font ?? Helvetica 12)`, and only in a document that `canEdit`.
  - `setFont` is already tested (Task 1). This task is the wiring.

- [ ] **Step 2: Run `swift build` and `swift test` and check that all tests pass**

- [ ] **Step 3: Commit** with the message "Show Fonts sets a selected text box's font and size".

### Task 4: Home window

**Files:**
- Create: `Sources/Folio/Home.swift`, with `struct Home: View` and `struct RecentFile: View`.
- Modify: `Sources/Folio/App.swift`. The scenes and their launch behaviour, plus `DocumentView(doc:url:)`.
- Modify: `Sources/Folio/Window.swift`. `DocumentView` takes `url: URL?`. Its `onAppear` calls `dismissWindow(id: "home")`. Its `onDisappear` waits one run-loop turn, then calls `openWindow(id: "home")` if `NSDocumentController.shared.documents.isEmpty`.

**Interfaces:**
- Produces: the window id `"home"`, titled "Home". `DocumentView.init(doc: FolioDocument, url: URL?)`.

- [ ] **Step 1: Implement**
  - Scenes:
    - `DocumentGroup … .defaultLaunchBehavior(.suppressed)`.
    - `Window("Home", id: "home") { Home() }` with `.defaultLaunchBehavior(.presented)`, `.restorationBehavior(.disabled)`, `.windowStyle(.hiddenTitleBar)` and `.defaultSize(width: 760, height: 520)`.
  - `Home`:
    - A header with the app icon, "Folio" and an Open… button (`NSDocumentController.shared.openDocument(nil)`).
    - "Recent", then a `LazyVGrid(.adaptive(minimum: 150))` of `RecentFile` tiles. The list is `recentDocumentURLs` filtered by `fileExists`, reloaded `onAppear`.
    - With none: `ContentUnavailableView("No Recent Files", systemImage: "doc.richtext", description: "PDFs you open show up here. You can also drop one on this window.")`.
    - `.dropDestination(for: URL.self)` opens the dropped URLs that conform to `.pdf`.
    - Opening: `Task { do { try await openDocument(at: url) } catch { NSApp.presentError(error) } }`.
  - `RecentFile`:
    - A plain button tile: a thumbnail at 120×150, the name without its extension (2 lines) and the folder name (caption, secondary).
    - A background shows on hover. `.help(url.path)`. Context menu: Show in Finder.
    - The thumbnail is `QLThumbnailGenerator.Request(fileAt:size:scale: 2, representationTypes: .thumbnail)` in `.task`, with `NSWorkspace.shared.icon(forFile:)` until then.

- [ ] **Step 2: Run `swift test` and check that all tests pass. After the DMG job finishes, run `./build.sh`**

- [ ] **Step 3: Verify at runtime.** Use a scratch copy of a PDF; keep the owner's files out of it.
  - A launch with no saved state shows Home.
  - Opening a recent file closes Home.
  - Closing the last document brings Home back.
  - With all windows closed, a Dock click shows Home.
  - `open -a build/Folio.app file.pdf` with Folio not running leaves only the document (Review Focus 1).
  - ⌘Q with a document open doesn't open Home. On relaunch the document comes back without Home (Review Focus 2).

- [ ] **Step 4: Commit** with the message "Open on a home window of recent files instead of the Open panel".

### Task 5: Save As

**Files:**
- Modify: `Sources/Folio/App.swift`. `CommandGroup(after: .saveItem)` gets Save As… ⇧⌘S: `NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil)`, disabled with no viewer.

- [ ] **Step 1: Read the File menu that SwiftUI makes (System Events)**
  - If Duplicate holds ⇧⌘S, take it off Duplicate so that Save As has it.
  - If SwiftUI already lists a Save As item, give that item ⇧⌘S rather than adding a second one.

- [ ] **Step 2: Implement, `./build.sh`, and verify at runtime** (Review Focus 3)
  - Use a scratch copy, add a note, then Save As to a new name.
  - The window's title becomes the new name, and the new file holds the note.
  - Record what the original holds.

- [ ] **Step 3: Commit** with the message "Add File › Save As… ⇧⌘S".

### Task 6: Keys, page box and last page

**Files:**
- Modify: `Sources/Folio/Annotations.swift`. `Tool.key: String` is a switch with the spec's letters. `Tool.init?(key:)` finds it among `allCases`.
- Modify: `Sources/Folio/Canvas.swift`.
  - `keyDown`, only while `viewer.doc.canEdit`:
    - Arrows (123–126) nudge `selected` 1 pt, or 10 pt with Shift, through `doc.change("Move", …)`.
    - Delete (51, 117) deletes, as now.
    - Esc (53) deselects and sets Select, but only when something is selected or the tool isn't Select. Otherwise `super` (Read Mode's exit).
    - A letter with no ⌘, ⌥ or ⌃ picks its tool.
  - `init` observes `.PDFViewPageChanged` on itself and sets `viewer.pageIndex`.
- Modify: `Sources/Folio/Window.swift`.
  - `Viewer.pageIndex = 0`.
  - `Viewer.go(toPage number: Int)`, 1-based and clamped.
  - `static func lastPage(of url: URL) -> Int?` and `static func remember(page index: Int, of url: URL)`. They use UserDefaults `pages` [path: index]. `remember` drops the paths not in `recentDocumentURLs`, then sets this one.
  - Toolbar item: `TextField(value:format: .number)`, 40 wide, then "of N". Hidden while the PDF is locked.
  - `DocumentView` reads `lastPage(of: url)` once, in init, and goes there in `.task`. `onChange(of: viewer.pageIndex)` calls `remember`.
  - The ToolBar picker's help tag is `"\(name) (\(key.uppercased()))"`.
- Test: `Tests/FolioTests/ViewerTests.swift`

**Interfaces:**
- Produces: `Tool.key`, `Tool(key:)`, `Viewer.pageIndex`, `Viewer.go(toPage:)`, `Viewer.lastPage(of:)` and `Viewer.remember(page:of:)`.

- [ ] **Step 1: Write the failing tests**
  - `testKeysPickToolsNudgeAndDeselect`. Use the key events from `NSEvent.keyEvent(with: .keyDown, …)`.
    - "t" sets `.text`. "v" sets `.select`.
    - With a selected rect: right arrow moves `bounds.minX` by +1, shift+up moves `minY` by +10, and undo moves it back.
    - Esc gives `selected == nil` and `.select`.
    - ⌘T leaves the tool unchanged.
    - In a document whose `canEdit` is false, "t" doesn't change the tool (Review Focus 4). Use `makePDF` written with a permissions password via `PDFDocumentWriteOption.ownerPasswordOption` and `.userPasswordOption ""`, reopened.
  - `testPageBoxGoesAndClamps`. With 3 pages:
    - `go(toPage: 2)` gives `currentPage == p[1]` and `pageIndex == 1`.
    - `go(toPage: 99)` gives the last page. `go(toPage: 0)` gives the first.
  - `testLastPageKeepsOnlyRecentFiles`. `remember(page: 3, of: a)`, then `remember(page: 5, of: b)`. The test process has no recents, so `lastPage(of: a) == nil` and `lastPage(of: b) == 5`. Clean up the `pages` key afterwards.

- [ ] **Step 2: Run `swift test --filter ViewerTests` and check that it fails to compile**

- [ ] **Step 3: Implement as in Files**

- [ ] **Step 4: Run `swift test` and check that all tests pass**

- [ ] **Step 5: Commit** with the message "Tool keys, nudging, Esc, a page box and reopening at the last page".

### Task 7: README, install, final check

**Files:**
- Modify: `README.md`. Features: the home window, Save As, matched text boxes, Show Fonts, keys, the page box and the last page. Note what Task 5 found about Save As if it surprises.
- Modify: `docs/superpowers/specs/2026-10-20-home-save-as-matched-text-design.md`, with any decision changed during the build.

- [ ] **Step 1: Run `swift test` (all) and `./build.sh`. Expect all tests to pass and the build to be signed**
- [ ] **Step 2: Install.**
  - If Folio is running from `/Applications`, quit it with AppleScript. Autosave keeps the documents.
  - `ditto build/Folio.app /Applications/Folio.app`, then relaunch it if it was running.
  - `codesign --verify /Applications/Folio.app`.
- [ ] **Step 3: Commit** with the message "Describe the home window, Save As and matched text in the README". Don't push.
