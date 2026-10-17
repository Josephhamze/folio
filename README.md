# Folio

A PDF viewer and editor for the Mac, built on Apple's PDFKit, the engine Preview uses. It needs macOS 26 or later on Apple Silicon.

## Build and run

```sh
./build.sh run
```

This builds `build/Folio.app`, signs it and starts it. `./build.sh` alone only builds. You need Xcode.

The app is signed with your Apple Development certificate when you have one, and ad hoc otherwise.

To keep Folio, copy `build/Folio.app` to `/Applications`. It then appears in Finder's Open With menu for PDFs, without making itself the default.

The icon, also in `icon/logo.png`, is drawn by `icon/icon.swift`. After changing it, `swift icon/icon.swift` redraws both.

`swift test` runs the tests.
