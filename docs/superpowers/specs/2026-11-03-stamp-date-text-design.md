# Folio: stamps, dates, every page, text recognition and smaller files

## Intent

The owner asked for what Folio is missing, chosen by the builder. The owner's businesses run on paper that is signed the way it is in Central Africa and China: a contract there needs a signature, the company's stamp (a cachet, or a chop, 公章), the date, and initials on every page. Much of it arrives as scans, and much of it goes out over slow, costly mobile data. Folio signs, but has no stamp, no date, no way to initial thirty pages at once, no way to search a scan, and no way to make a file smaller. These fill those gaps, on the Mac, iPhone and iPad, in the way Folio already works.

## Goals

**Stamp**
- A Stamp tool (key C) beside Sign and Initial. It places the company's stamp: a click puts it at the usual size, 120 points a side, or a drag sizes it, keeping its shape. It is then selected, to drag into place.
- The stamp is a picture: a photo or scan of the stamp on paper, chosen once from Photos or Files in the stamp's pad. Folio lifts the ink off the paper: the paper becomes clear, the ink keeps its colour, and the picture is cropped to the ink, at most 1,000 pixels a side. So it looks stamped on the page, not pasted.
- It goes into the file as the annotation's appearance, so other apps show it. It is kept in Folio's settings, as signatures are. Tools › Edit Stamp… changes it.

**Signatures from a picture**
- The signature and initials pads get a third way, Image, beside Draw and Type, with the same lifting. A signature scanned on paper becomes a signature Folio places.

**Date**
- A Date tool (key D). A click places today's date, in the region's short form ("03/11/2026" in France, "11/3/2026" in the US), in the font, size and colour of the nearest text, on its line when it's beside one: the Text Box tool's rules. It is then selected; a double-click or a tap edits it.

**Add to Every Page**
- With a mark selected, Add to Every Page puts a copy of it on every other page, at the same place, as one undo step: initials on each page of a contract, a stamp on each page of an invoice. Folio says how many pages got one.
- It is in the tool bar, beside Delete, in the Tools menu and in a mark's right-click menu.

**Recognize Text**
- Tools › Recognize Text reads the words on each page that has no text, such as a scan, with Apple's on-device text recognition, which reads English, French and Chinese among others. The words go under the page as invisible text, so Find finds them and they can be selected and copied. The page looks as it did, and keeps its marks, turn and crop.
- It shows its progress over the pages, and says how many pages it read. It is one undo step. Pages that already have text are left alone.

**Reduce File Size** (Mac)
- Tools › Reduce File Size rewrites the document through macOS's own Reduce File Size filter: pictures become JPEG at 144 dpi. It keeps the result only when it is smaller, says the sizes before and after ("4.2 MB → 780 KB"), and is one undo step.

**Send Page as Picture** (added once the rest was built)
- Tools › Send Page as Picture shares the page in view, with its marks, turn and crop, as a JPEG. Signed and stamped pages mostly travel in WhatsApp and WeChat, where a picture shows at once and a PDF is a file to download.

**Organize Pages** (added once the rest was built)
- The first design planned it; its document side was built and tested, but not its screens. Organize Pages, in the window's bar and the new Pages menu (⌥⌘O), lays the pages out as a grid over the page view. A click selects a page, ⌘ and ⇧ clicks select more, and on iPhone and iPad a tap selects or deselects one. Pages dragged in the grid move in front of the page they're dropped on, or to the end.
- The bar then rotates the selected pages (⌘L, ⌘R), inserts a blank page or pages from PDFs and pictures after them, extracts them into a file of their own, and deletes them. The Pages menu does the same to the page in view when not organizing. Leaving the grid shows the first selected page.

**Apply Redactions** (added once the rest was built)
- The Redact tool marked areas, but nothing applied them, so the words stayed in the file under a red box. Tools › Apply Redactions now burns them in: each page with marks becomes a picture of itself with the marked areas black, and gets back the words read from the picture, so the rest can still be found. Marks that overlap a redaction go, since they could tell what it hid. It's one undo step, and all or nothing: a page that can't be redacted leaves every page as it was.
- Placing a redaction mark says that Apply Redactions takes out what's under the marks.

**Password…** (added once the rest was built)
- Tools › Password… sets the password that opens the file once it's saved, changes a file's own, or takes it off: a contract sent by email or WhatsApp can then be opened only by whoever is told the password. It's one undo step, and says it applies once the file is saved.

**Tools on iPhone**
- The navigation bar gets a Tools menu with what the menu bar's Tools menu has. Without it, a signature saved on an iPhone could never be changed: the pad opened only when none was saved, and only iPad has a menu bar.

**Tests on GitHub**
- A workflow runs the Mac tests on macOS 27 and the iOS tests on the simulators `build.sh` names, on every push, on GitHub's free runners for public repositories. The iOS screenshots are kept with each run. `./build.sh ios-test <test>` runs one test alone.

## Non-goals

- Scanning with the camera; combining and splitting files; restrictions on printing, copying and changes, and the properties sheet; French and Chinese for Folio's own words. They are next.
- Choosing the date's format, or a stamp's colour. The date follows the region; the stamp keeps its ink.
- Resizing a placed stamp: as with signatures, it's placed again at another size.
- Recognizing text on pages that have some, or on parts of pages.
- Reducing file size on iOS, which has no Quartz filters.

## Anti-goals

- A stamp that shows a white box around its ink, or loses its colour.
- Text recognition that changes how a page looks, drops its marks, or can't be undone.
- A smaller file that is saved larger again, or that loses its password or marks.
- New dependencies. Vision, PhotosUI, ImageIO and Quartz are Apple's.

## Decisions (the builder's)

- **Signature**, the enum, gets a third case, `image(Data)`: the PNG of the lifted ink. `SignatureAnnotation` draws the picture into its bounds when it has one, else its outline, and copies it as it copies the outline.
- **Lifting the ink** works on the darkest of each pixel's red, green and blue. The paper's level is the 90th percentile of that over the picture, and the ink's the 2nd. A pixel within 15% of the paper is clear; one 60% of the way to the ink, or darker, is solid; between, it is partly clear. Its colour is taken out of the paper's: the share of white it lets through is removed, so the edges keep the ink's colour. The picture is read upright (its photo orientation applied) and no larger than 1,000 pixels, then cropped to the pixels at least half solid, with two pixels to spare.
- **Pictures come from** PhotosPicker, which needs no permission, and the file importer, on both platforms.
- **The date** is a text box from `textBox(at:on:)` holding `Date.now.formatted(date: .numeric, time: .omitted)`, grown to fit, added as "Add Date".
- **Add to Every Page** copies the mark with `copy()`. On a page of another size the copy keeps its size, and its middle sits as far across and up the page as the mark's does on its own. A page turned another way than the mark's gets its copy unturned: noted as a shortcut.
- **Recognize Text** uses Vision's accurate model, which can't run on GitHub's virtual Macs. There the tests that read text skip themselves, and the tests of the page rebuilt from given lines, which need no Vision, still run. It renders each page without text at 300 dpi (fewer dots for a page past 4,000 pixels a side), in grey, without its annotations, recognizes it with Vision's `RecognizeTextRequest` (accurate, language detected automatically, language correction on), and rebuilds the page: the old page's drawing, then each line as invisible Helvetica, sized to the line's box and stretched to its width, so a selection lands on the words. Fonts are found for other scripts as Core Text finds them. Each new page keeps the old one's rotation, crop box and copies of its annotations, all but popups. Pages are rebuilt at the end, and swapped in with one `setPages`, so undo puts the old pages back. While it runs the tools are off.
- **Reduce File Size** writes a copy, away from the main thread, with the `QuartzFilter` write option and `/System/Library/Filters/Reduce File Size.qfilter`. It reads the result back and unlocks it with the document's password when it is encrypted. A result that would lose the file's encryption is thrown away, and so is one finished after the document changed. Otherwise it is swapped in with one `change`, and the window stays on its page. PDFKit's own write options, `saveImagesAsJPEGOption` and `optimizeImagesForScreenOption`, were tried for iOS. They shrink only the pictures PDFKit made from photos, not those of a file it read (3.4 MB stayed 3.4 MB, where the filter made 407 KB), so iOS has no Reduce File Size.
- **The Tools menu** is one view, `ToolsMenu`, in the menu bar's Tools menu and in the iOS navigation bar.
- **Send Page as Picture** is a `ShareLink` in the Tools menu, whose item makes the JPEG only when it's shared: the page drawn by PDFKit's `draw(with: .cropBox, to:)`, which turns and crops it itself, on white, at 144 dpi, quality 0.85. It's named "Page n".
- **Apply Redactions** renders each marked page as `render` does for Recognize Text, in colour at 300 dpi without its annotations, with the marks' boxes filled black in page space, so a turned page or one whose media box doesn't start at 0,0 is blacked exactly where marked. The picture is kept as a JPEG at quality 0.85 (a page-sized picture kept as drawn would weigh tens of megabytes), drawn over the page's media box by `rebuilt`, with the recognized words under it. Recognition that fails, as on GitHub's Macs, still redacts, leaving the page without text.
- **The password** is the document's `newPassword`, written as both the user and owner password by `snapshot`, so whoever opens the file can do anything with it. PDFKit saves a file opened encrypted with its own protection whatever it's asked, so setting or removing a password on one first moves its pages, bookmarks and attributes into a new, unprotected document, and undo moves them back. Only a document Folio may edit can have its password changed: a restricted file needs its permissions password first.
- **The organizer** is a SwiftUI grid laid over the page view, which stays alive under it, so the page view keeps its place and a page can be shown as the grid goes. Each page is drawn once per change, as it shows, 320 pixels on its longest side. A drag carries the document's address and the page's number as text, so text dragged in from elsewhere, or a page from another window, is refused. The page actions are one view, `PageActions`, in the Pages menu and in the bar while organizing.
- **Insert from File…** and **Extract Pages…** use SwiftUI's file importer and exporter on both platforms. Files are read whole while they may be read. Extracted pages are saved as a new file named after the document, rather than opened in a new window, since iPhone shows one document at a time.
- **Tool keys:** C for Stamp (cachet, chop), D for Date.

## Testing

- Lifting: paper goes clear, ink keeps its colour, the picture is cropped to the ink.
- A picture stamp is placed in its box keeping its shape, and is the same picture in the saved file.
- The date tool places today's date as one change, selected.
- Add to Every Page puts copies on every other page at the same place, one undo step, for a drawn mark, a stamp read back from a file and a date.
- Recognize Text makes a scan searchable, in English, French and Chinese, keeps marks, turn and crop, and undoes; pages with text are left alone.
- Reduce File Size shrinks a photo PDF, stays small once saved, and leaves a text PDF alone.
- On iOS: a tap places a stamp and a date; Add to Every Page from the tool bar; the Tools menu opens the pads.
- Apply Redactions: the words under a mark are gone from the window and the saved file, the box is black, other pages keep their text, a mark overlapping a redaction goes and one clear of it stays, the page keeps its turn, and undo brings it all back. A redacted photo page stays a JPEG.
- Password: a password set goes on when saved and undoes; a new one replaces a file's own; removing one keeps the pages, marks, bookmarks and title, and undoes.
- Organizing: drops take only pages dragged in the same window; inserted pages are selected; leaving shows the first selected page. On iOS, a tap selects a page in the grid, the bar deletes it, and Undo puts it back.
