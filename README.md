<p align="center">
  <img src="icon/logo.png" width="128" alt="">
</p>

<h1 align="center">Folio</h1>

<p align="center">
  A native PDF viewer and editor for the Mac, built on PDFKit, the engine behind Preview.<br>
  Free and open source. No account, no subscription.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20PDFKit-F05138?logo=swift&logoColor=white" alt="Swift, SwiftUI and PDFKit">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

![Folio showing a two-page brief with a highlight, an underline, a note, a circled total and an arrow](docs/screenshot.png)

## Features

- **Read.** The sidebar shows thumbnails, bookmarks and every comment. View one page, a continuous scroll or two pages side by side, zoom, and switch to a full-screen Read Mode. Find counts the matches and steps through them.
- **Mark up.** Highlight, underline, strike through, add notes and text boxes, and draw rectangles, ovals, lines, arrows and freehand ink, in any colour. Select a mark to move it or recolour it.
- **Sign.** Draw or type your signature and initials once. Then place them with a click, or drag a box to size them. They're saved as vector outlines, so they stay sharp at any zoom and in other PDF apps.
- **Fill in forms.** You can also fix a line of text by typing over it. The original text stays underneath in the file, and Folio tells you so.
- **Protected files.** Folio asks for a file's password in the window. It respects an author's editing restrictions until you enter the permissions password, and saving keeps the file encrypted.
- **Undo.** Every change can be undone and redone.
- **Print**, and open PDFs from Finder's **Open With** menu. Folio doesn't make itself your default PDF app.

## Install

Folio isn't notarised, so you build it from source. You need macOS 26 or later on Apple Silicon, and Xcode.

```sh
git clone https://github.com/Josephhamze/folio.git
cd folio
./build.sh run
```

This builds and signs `build/Folio.app`, then opens it. To keep Folio, copy `build/Folio.app` to `/Applications`.

## Development

- `swift test` runs the tests.
- `./build.sh` builds the app without opening it. It signs the app with your Apple Development certificate if you have one, and ad hoc if you don't.
- `swift icon/icon.swift` draws the icon from code, into `icon/Folio.icns` and `icon/logo.png`.
- The design and the build plan are in [`docs/superpowers`](docs/superpowers).

## Roadmap

- **Organise pages:** reorder, rotate, delete, insert and extract pages, and combine or split files. The document side of this is built and tested. The screens aren't built yet.
- **Passwords:** add or remove a file's password, plus a document properties sheet.
- **Redaction:** apply redactions. For now the Redact tool only marks areas.
- **Other tools:** text recognition, reducing file size and exporting pages as images.

## License

[MIT](LICENSE) © 2026 Joseph Hamze
