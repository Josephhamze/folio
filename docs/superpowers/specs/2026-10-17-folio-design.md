# Folio: design

## Intent

A free, native Mac PDF viewer and editor that covers what the owner would otherwise use Acrobat for. It was prompted by the viral ArtCraft suite: its Acrobat clone, PdfCraft (github.com/storytold/pdfcraft), supplies the feature checklist, not code. Folio is built on Apple's PDFKit, the engine Preview uses, so rendering is Preview-grade and the code stays small. The owner asked for simplicity: the simplest working solution, the fewest lines, no dependencies.

## Goals (all of v1)

**Read**
- Open PDFs from Finder (Folio is listed in Open With), File › Open, or by dropping them on the Dock icon; Open Recent. Each document opens in its own window, as a tab.
- Continuous, single page and two pages. Zoom in, zoom out, actual size, zoom to fit, and pinch to zoom.
- A sidebar with three panes: page thumbnails, bookmarks (the document's outline), and comments.
- Find as you type in the toolbar's search field. It shows the match count ("3 of 16"), steps with ⌘G and ⇧⌘G, and highlights every match.
- Read mode: full screen, with no sidebar and no toolbar.
- Dark mode follows the system.
- Password-protected files ask for their password inside the window.
- Links, text selection and copy work (PDFKit gives these).

**Comment**
- Highlight, underline and strike through selected text, in a chosen colour.
- Note (sticky note), text box, rectangle, oval, line, arrow, and pen (freehand).
- Click an annotation to select it. Then you can drag it to move it, change its colour, or press Delete to delete it. There are no resize handles: delete it and draw it again.
- The comments pane lists every annotation by page, with its text. A click goes to the annotation. Notes are written there; text boxes are typed in place on the page.

**Fill and sign**
- Fill form fields with PDFKit's own widgets. Each change can be undone and marks the document edited.
- Signature and initials: draw each with the trackpad or mouse, or type it (shown in a script font). Each is saved once for the user. The Sign and Initial tools place them with a click, or at the size of a dragged box, keeping their shape.

**Edit**
- Add text anywhere: the text box tool.
- Fix a line of existing text. Click a line and it is covered by a white text box holding the same words, in the closest font and size, ready to edit. The original text stays underneath in the file; the UI says so once.

**Organize**
- Organize mode replaces the page view with a grid of pages.
  - Select pages: click, ⌘-click and ⇧-click.
  - Drag pages to reorder them.
  - Rotate left and right, and delete.
  - Insert a blank page, or insert pages from PDFs or images.
  - Extract the selected pages into a new document.
  - Split the document every N pages into files in a chosen folder.
- File › Combine Files… merges chosen PDFs and images into a new document. This is also how images become a PDF.

**Protect**
- Set a password to open the file, and/or restrict printing, copying and changes with a permissions password. Protection can also be removed.
- Redaction:
  - Draw redaction boxes, then choose Apply Redactions.
  - Each page with boxes becomes an image with the boxes burned in black, so the text under them is gone from the file.
  - Text recognition then runs on that image, so the rest of the page stays searchable.
  - Annotations that overlap a box are removed.

**Tools**
- Recognize Text (OCR): pages with no text get an invisible text layer from Apple Vision. The page's own drawing is kept as it is.
- Reduce File Size: rewrites the document through macOS's "Reduce File Size" Quartz filter and reports the size before and after.
- Export the pages as PNG images into a folder.
- Print.
- Document properties: title, author, subject and keywords, all editable; page count, PDF version and protection.

Everything that changes the document can be undone and is named in Edit › Undo. It marks the document edited, and the system saves it with autosave and versions, like any Mac document.

## Non-goals

- Rewriting a PDF's own text (true content editing).
- Office and Word conversion.
- Digital ID (certificate) signatures.
- Building forms.
- AI features.
- Windows, web and iOS.
- Editing bookmarks, comment replies, page labels.
- Search and redact; watermarks, headers and footers.
- OCR of pages that already have text.

## Anti-goals

- A fork of PdfCraft, or any third-party dependency.
- Losing the user's work. A save must never strip a file's password without being asked to, and every destructive change can be undone.
- Clever code, layers of abstraction, wrappers.

## Constraints

- Its own repo, `~/Claude Work /Folio`, on git, committed as the work goes. `.gitignore` has `.env`.
- Swift, with SwiftUI and AppKit (PDFView), PDFKit, Vision and Quartz. No packages.
- Built the way Notch is: a SwiftPM executable, plus `build.sh`, which makes `build/Folio.app` and signs it with the Apple Development identity (ad-hoc when there is none). `./build.sh run` restarts the app.
- macOS 26 or later, Apple Silicon. Swift tools 5.9 (Swift 5 language mode), as in Notch.
- An app icon drawn by `icon/icon.swift`, as in Notch.

## Decisions (Claude's calls)

- **Restricted files:** a file restricted by a permissions (owner) password is honoured, as Preview and Acrobat do.
  - The tools that change the document, and Remove Protection, stay off.
  - A bar offers to enter the permissions password, which unlocks them.
- **Drawing a signature:** done by clicking and dragging in a pad, with the trackpad or a mouse. It is not Preview's finger-on-the-trackpad capture.
- **Dark mode:** applies to the window around the pages. The pages stay white, as in Preview.
- **Launch:** opening Folio without a file shows the Open panel, as Preview does. SwiftUI's document apps do this on their own (verified in a spike).
- **Text box fill:** a free-text annotation's `color` is its fill. It is saved and drawn after reloading (verified), so fixing a line needs just one white-filled text box.
- Name: Folio. Bundle id: `com.josephhamze.folio`. Folio is an Editor for `com.adobe.pdf` at the Alternate rank, so it shows in Open With without taking over the default app.
- **The document** is a SwiftUI `DocumentGroup` with a `ReferenceFileDocument` that holds a `PDFDocument`.
  - The macOS 27 SDK marks `ReferenceFileDocument` deprecated, for a future release, in favour of the new `Document` protocol.
  - That protocol is macOS 27 only and needs more code: reader and writer types, async snapshots.
  - `ReferenceFileDocument` works on 26 and 27 without warnings.
- New (⌘N) makes a blank one-page document at the system's paper size. An empty `PDFDocument` cannot be written (verified).
- **Undo:**
  - Each edit is a pair of closures, do and undo, registered with the window's undo manager. Undoing registers the reverse pair, so redo works.
  - Page-structure edits all go through one operation that sets the page list: rotate, delete, insert, move, redact and OCR. Its undo restores the previous list of the same `PDFPage` objects, with their rotations.
- **Passwords:**
  - PDFKit keeps a file's encryption on a plain save (verified).
  - New protection is applied with write options: user password, owner password and access permissions.
  - Removing protection moves the pages into a fresh `PDFDocument` (verified: annotations, bookmarks and the title survive; the copy is unencrypted).
- **Signatures** and initials are stored in UserDefaults: strokes for a drawn one, text for a typed one.
  - Each is placed as one filled outline, a stamp annotation Folio draws itself: the same picture at any size, and neither a comment nor a text box.
  - A drawn one is inked: smoothed through the midpoints of its points, and thinner where the pen moved faster.
  - A typed one is its letters' outlines in Snell Roundhand, with the hairlines thickened to a pen's line.
  - PDFKit writes Folio's drawing into the file as the stamp's appearance (verified), so other apps show it. The stamp copies its outline itself, or pages copied for Extract and Split lose it (verified).
- **Redaction marks** are square annotations tagged by their name. Apply renders the page at 300 dpi.
- **OCR:**
  - `VNRecognizeTextRequest` at the `.accurate` level.
  - The new page is the original page drawn into a PDF context, plus invisible text fitted to each recognized line (verified: `findString` finds it).
  - It runs off the main thread and shows its progress.
- **Compression:**
  - PDFKit's own JPEG and optimize write options change nothing (verified).
  - Writing with the `"QuartzFilter"` option set to `/System/Library/Filters/Reduce File Size.qfilter` (JPEG at 0.7, images at 144 dpi, at most 2400 px) cut a 3-page photo PDF from 4.2 MB to 0.78 MB (verified).
  - On a file with no photos it can grow, so Folio keeps the smaller of the two and says so.

## Verified on this Mac (macOS 27.2, Xcode 27.0, Swift 6.4), 2026-10-17

- `PDFDocumentSaveTextFromOCROption` adds no text to an image-only page, so OCR is Folio's own.
- Vision's `.accurate` text recognition takes about 24 s the first time in a process (loading its model), then about 0.07 s a page. `.fast` starts at once but reads worse.
- Free-text (with a custom font) and ink annotations come back from a save with appearance streams.
- A `PDFDocument` that was opened encrypted and unlocked stays encrypted after `dataRepresentation()`.
- A `PDFAnnotation` subclass's own `draw(with:in:)` is saved as its appearance stream, as vector paths; PDFium, Chrome's renderer, shows it.
- `PDFView` draws each annotation (not form fields) into a layer of its own at one pixel a point and stretches it with the zoom, so annotations look pixelated on a Retina screen. No setting changes this. The canvas redraws those layers at the zoom after each tile draw and each change, at most 4096 pixels a side.

## Left to the builder

- How the code is split into files; the view structure, toolbar layout, keyboard shortcuts, colours, and the icon's design.
- How the Organize grid is built: a SwiftUI grid, or `PDFThumbnailView`, which has `maximumNumberOfColumns`.
- How changes to form fields are noticed, so they can be undone.
- Which tests to write.

## Testing

- XCTest over the document operations, with no UI:
  - page operations with undo and redo; extract, split and combine; annotations;
  - redaction removes text; OCR adds text that can be found;
  - protection on and off; compression shrinks a photo PDF; encrypted files stay encrypted.
- A live check of the built app: open a sample PDF, try each tool, and look at screenshots of the Folio window only, never the whole screen.
