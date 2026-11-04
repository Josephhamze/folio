<p align="center">
  <img src="icon/logo.png" width="128" alt="">
</p>

<h1 align="center">Folio</h1>

<p align="center">
  A native PDF viewer and editor for the Mac, built on PDFKit, the engine behind Preview.<br>
  Free and open source. No account, no subscription.
</p>

<p align="center">
  <a href="https://github.com/Josephhamze/folio/releases/latest/download/Folio.dmg"><img src="https://img.shields.io/badge/Download-Folio.dmg-2ea44f?logo=apple&logoColor=white" alt="Download Folio.dmg"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20PDFKit-F05138?logo=swift&logoColor=white" alt="Swift, SwiftUI and PDFKit">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

![Folio showing a two-page brief with a highlight, an underline, a note, a circled total and an arrow](docs/screenshot.png)

## Features

- **Home.** Folio opens on your recent files, shown as thumbnails. Click one to open it, or drop a PDF on the window. Each file reopens at the page you left it on.
- **Read.** The sidebar shows thumbnails, bookmarks and every comment. View one page, a continuous scroll or two pages side by side, zoom with a pinch or ⌘ and the scroll wheel, and switch to a full-screen Read Mode. Type a page number in the toolbar to go to it. Find counts the matches and steps through them.
- **Mark up.** Highlight, underline, strike through, add notes and text boxes, and draw rectangles, ovals, lines, arrows and freehand ink, in any colour. Select a mark to drag it, nudge it with the arrow keys, recolour it, or delete it with the Delete key or the trash in the tool bar. Right-click any mark to delete it, whatever the tool. A signature, note or text box you place stays selected, ready to drag into place. Single keys pick the tools: V Select, H Highlight, T Text Box, S Sign, C Stamp, D Date. Each tool's tooltip shows its key.
- **Text that matches.** Click with the Text Box tool and type. The text takes the font, size and colour of the nearest text on the page. Beside a line, it sits on that line, so it looks typed into the document. Show Fonts (⌘T) changes a box's font and size.
- **Sign.** Draw or type your signature and initials once, or take them from a photo or scan. Then place them with a click, or drag a box to size them. Drawn and typed ones are saved as vector outlines, so they stay sharp at any zoom and in other PDF apps.
- **Stamp and date.** Photograph your company's stamp printed on white paper, and the Stamp tool places it like a rubber stamp: Folio lifts the ink off the paper and keeps its colour. The Date tool types today's date beside the line you click, in that line's font.
- **Every page at once.** Select a mark and choose Add to Every Page, in the tool bar or the mark's menu, to put a copy at the same place on every page: your initials on each page of a contract, or the stamp on each page of an invoice.
- **Scans you can search.** Tools › Recognize Text reads the words on scanned pages, in English, French, Chinese and many other languages, on your device. Find then finds them, and you can select and copy them. The pages look as they did.
- **Organize pages.** Organize Pages (⌥⌘O), in the window's bar or the Pages menu, shows the pages as a grid. Select them with a click, ⌘ or ⇧ click for more (a tap on iPhone and iPad), and drag them into a new order. Rotate them (⌘L, ⌘R), insert a blank page or pages from PDFs and pictures, extract them into a file of their own, or delete them. Out of the grid, the Pages menu does the same to the page in view. Split… there splits the document into files of a few pages each, in a folder you choose, named after it and numbered; a protected file's pieces keep its password.
- **Scan paper.** On iPhone and iPad, Scan Pages…, in Organize Pages, scans paper with the camera into the document. On the Mac, File › Import from iPhone or iPad › Scan Documents does the same with your iPhone. Tools › Recognize Text then makes the pages searchable.
- **Send a page as a picture.** Tools › Send Page as Picture shares the page you're on, with its marks, as a picture, for a chat app where a picture shows at once and a PDF is a file to download.
- **Redact.** Box what must go with the Redact tool (X), then choose Tools › Apply Redactions. Each marked page becomes a picture of itself with the boxes blacked out, so the words under them are gone from the file, not just covered. Folio reads the rest of the page back, so it can still be found, and drops any mark over a box.
- **Smaller files.** On the Mac, Tools › Reduce File Size saves the pictures as JPEG at 144 dpi, so a scanned contract is light enough to send over mobile data. Folio shows the size before and after, and keeps a file's password.
- **Fill in forms.** You can also fix a line of text by typing over it. The original text stays underneath in the file, and Folio tells you so.
- **Protected files.** Folio asks for a file's password in the window. It respects an author's restrictions until you enter the permissions password, and saving keeps the file encrypted. Tools › Password… sets the password that opens a file, changes it, or takes it off, once the file is saved. It can also restrict printing, copying and changes to whoever has a second, permissions password; apps that respect restrictions ask for it, though not every app does.
- **Properties.** Tools › Properties… sets the title, author, subject and keywords a file keeps about itself, which other apps and searches show.
- **Save.** Your changes stay out of the file until you save them with ⌘S. Closing or quitting with unsaved changes asks whether to save them. File › Save As… (⌥⇧⌘S) saves the document under a new name, and you keep working in the new file.
- **Undo.** Every change can be undone and redone.
- **English, French and Chinese.** Folio's menus, buttons and messages follow your device's language: English, French or Simplified Chinese. On the Mac, System Settings › General › Language & Region › Applications sets Folio's language alone, and on iPhone and iPad, Settings › Apps › Folio › Language does.
- **Print**, and open PDFs from Finder. Folio asks once to be your default PDF app, and Home offers it while it isn't.

## Install

[Download Folio.dmg](https://github.com/Josephhamze/folio/releases/latest/download/Folio.dmg), open it and drag Folio to Applications. You need macOS 26 or later on an Apple Silicon Mac. Folio is signed and notarised by Apple, so it opens like any other app.

To build it yourself instead, you need Xcode:

```sh
git clone https://github.com/Josephhamze/folio.git
cd folio
./build.sh run
```

This builds and signs `build/Folio.app`, then opens it. To keep Folio, copy `build/Folio.app` to `/Applications`.

## Development

- `swift test` runs the tests.
- `./build.sh` builds the app without opening it. It signs the app with your Apple Development certificate if you have one, and ad hoc if you don't.
- `./build.sh dmg` makes `build/Folio.dmg` for a release, signed with your Developer ID and notarised. It needs a notarytool keychain profile named `notary`. Finder lays out the dmg's window, so macOS asks once to let your terminal control Finder.
- `./build.sh ios` builds the iPhone and iPad app and runs it in the simulator, on an iPhone 17 Pro. It needs XcodeGen: `brew install xcodegen`.
- `./build.sh ios-test` runs the iOS tests, on an iPhone 17 Pro and an iPad Pro 13-inch simulator. Give it a test's name to run only that one, such as `./build.sh ios-test FolioTouchTests`.
- GitHub runs the Mac and iOS tests on every push, and keeps the iOS tests' screenshots with each run.
- `./build.sh screenshots` takes the App Store's screenshots, into `build/app-store`.
- `./build.sh ios-release` uploads a build to App Store Connect. [`docs/app-store.md`](docs/app-store.md) has the one-time setup and the listing.
- `swift icon/icon.swift` draws the icon and the dmg window's background from code, into `icon/Folio.icns`, `icon/logo.png` and `icon/dmg.png`.
- The design and the build plan are in [`docs/superpowers`](docs/superpowers).
- [`Localization`](Localization) has Folio's French and Chinese, each line a translation of Folio's English. Words added to Folio need a line in both, and `swift test` checks that the two tables match each other, the code and the numbers and names each line takes.

## Roadmap

- **Bookmarks:** add, rename and delete bookmarks.

## License

[MIT](LICENSE) © 2026 Joseph Hamze
