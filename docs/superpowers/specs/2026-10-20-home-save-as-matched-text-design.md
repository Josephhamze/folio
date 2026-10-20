# Folio: home window, Save As, matched text and conveniences

## Intent

The owner asked for four things:
- Open, Save and Save As that are easy to find.
- A home page of recently opened files at launch, instead of the Open panel.
- Text boxes that take the font of the document around them, the way Acrobat's Add Text does, so what you type matches the page.
- Small conveniences, chosen by the builder.

Then the build goes into the owner's `/Applications/Folio.app`. Nothing is pushed to GitHub until the owner says so.

## Goals

**Home window**
- It opens at launch when there are no windows to restore, and from the Dock icon when no window is open. It closes when a document window opens. It comes back when the last document window closes, so Folio never sits with no window, as in Acrobat and Xcode.
- It shows the recent files (File › Open Recent's list, minus files that no longer exist) as a grid of Quick Look thumbnails. Each tile shows the file's name and its folder, and hovering over it shows the full path. A click opens the file. The context menu has Show in Finder.
- An Open… button shows the standard Open panel. PDFs dropped on the window open.
- With no recent files it says so and still offers Open….
- Window › Home shows it at any time. It is never restored from a previous session; the launch rule decides.

**Open, Save, Save As**
- Open… ⌘O, Open Recent and Save ⌘S stay as the system provides them, with autosave and versions.
- File › Save As… ⌥⇧⌘S, always visible. It writes the document to a new file, and the window then shows the new file. Duplicate keeps ⇧⌘S.
  - Changed during the build: the design gave Save As ⇧⌘S, the shortcut Acrobat and Office use. But SwiftUI's own Duplicate holds ⇧⌘S, and SwiftUI's Save As appears only while Option is held. Its menu items can't be retargeted, and replacing the whole save group also drops Close, Share and Revert To.

**Matched text**
- A click with the Text Box tool starts a box in the font, size and colour of the document text nearest the click: the closest run of one font and colour.
- A click beside a line of text, at that line's height, puts the box on the line. It sits the way an Edit Text cover sits, so it shares the line's baseline. That makes flat forms ("Name: ______") look typed. Elsewhere the box is centred on the click.
- On a page with no text, such as a scan, the box uses Helvetica 12 in black. Helvetica is one of the 14 base PDF fonts, so other apps show it the same way. The old default was 14 pt system font in the highlighter's colour, often yellow.
- A font that is only embedded in the PDF, and not installed, comes back from PDFKit as Helvetica at the right size. That is the fallback.
- The box starts empty, with the caret where you clicked, and grows as you type. Return or a click elsewhere ends the typing. The box joins the document only then, with its words, as one "Add Text" undo step. A box left empty is not added. Edit Text covers work the same way: a cover is added only if the words changed, and it may be emptied to blank out the line.
- Tools › Show Fonts ⌘T opens the system Fonts panel. It sets the selected text box's font and size, as one undoable change, and the box grows to fit.

**Conveniences**
- A page box in the window's toolbar shows "3 of 12". Type a page number and press Return to go to that page; numbers out of range go to the first or last page.
- Each recent file reopens at the page you left it on. The pages are kept for the files in the recent list only, so the store never grows past that list.
- Single keys pick tools while the page has the keyboard: V Select, H Highlight, U Underline, K Strike Through, N Note, T Text Box, R Rectangle, O Oval, L Line, A Arrow, P Pen, S Sign, I Initial, E Edit Text, X Redact. Each tool's help tag shows its key.
- With a mark selected, the arrow keys nudge it 1 pt, or 10 pt with Shift. Each nudge can be undone.
- Esc deselects and returns to the Select tool. When nothing is selected and Select is the tool, Esc still leaves Read Mode.

## Non-goals

- Saving the matched font into the file for other apps. A FreeText box names its font, and an app without that font substitutes one.
- Multi-line text boxes, alignment or a text style popover.
- Removing single files from the recent list (File › Open Recent › Clear Menu clears it), pinning, or search on the home page.
- A home tab inside document windows.

## Anti-goals

- Losing work. Save As must not leave the original file half-changed in a way the user can't undo. Check this against autosave in place.
- Wrappers or new dependencies. Use SwiftUI, AppKit, PDFKit and QuickLookThumbnailing only.

## Decided by the builder

- The home window is a SwiftUI `Window` scene. It uses `.defaultLaunchBehavior(.presented)` and `.restorationBehavior(.disabled)`. The DocumentGroup gets `.defaultLaunchBehavior(.suppressed)`, which Apple DTS confirmed stops the launch Open panel.
- The document view dismisses the home window on appear. On disappear, after a turn of the run loop, it reopens the home window if no document is left.
- Matching lives in `textBox(at:on:)` in Annotations.swift, a pure function with tests. It uses the page's lines (`selectionsByLine`) and each line's font and colour runs (`enumerateAttributes`). Each run is measured with `page.selection(for:)` over its range. `characterBounds(at:)` is not used: its indices don't match `selection(for:)`'s.
- Recent files come from `NSDocumentController.shared.recentDocumentURLs`, and files open through SwiftUI's `openDocument`. Errors are shown with `NSApp.presentError`.
- The last pages live in UserDefaults under `pages`, as path → page index. The entry is read when the window is made and written when the page changes.
