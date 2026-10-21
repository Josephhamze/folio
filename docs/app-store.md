# Folio on the App Store

What goes into App Store Connect for Folio on iPhone and iPad.

## Before the first upload

1. **Sign Xcode in.** In Xcode › Settings › Accounts, add the Apple Account of team PP6TZWTTLG. `./build.sh ios-release` then makes the Apple Distribution certificate and the App Store profile by itself.
2. **Make the app record.** In App Store Connect › Apps › New App, pick iOS, the name below, English (U.S.), the bundle ID `com.josephhamze.folio` and the SKU `folio`. If the bundle ID isn't offered, register it under Certificates, Identifiers & Profiles › Identifiers first.
3. **Upload.** `./build.sh ios-release` archives the app and uploads it. Each build's number is the commit count, so it always goes up.
4. **Screenshots.** `./build.sh screenshots` takes them, into `build/app-store`: three for the 6.9-inch iPhone (1320 × 2868) and three for the 13-inch iPad (2064 × 2752). App Store Connect scales them down for the smaller sizes.

## The listing

- **Name:** Folio: Mark Up & Sign PDFs
  - "Folio" alone is taken. The iTunes Search API found no app with this exact name in the US, UK or French store on 21 October 2026. App Store Connect has the last word, since it also knows names that are reserved but not yet live.
  - Other free names: "Folio: Sign & Mark Up PDFs", "Folio PDF: Sign & Mark Up", "Folio: Edit, Sign & Fill PDFs".
- **Subtitle:** Annotate and fill in forms
- **Promotional text:** Mark up, sign and fill in PDFs with a finger or Apple Pencil. Private by design: no account, no tracking and no subscription.
- **Keywords:** highlight,signature,editor,viewer,reader,document,notes,pencil,draw,underline,text,contract,esign
- **Primary category:** Productivity. **Secondary:** Business.
- **Price:** Free.
- **Support URL:** https://github.com/Josephhamze/folio/issues
- **Marketing URL:** https://github.com/Josephhamze/folio
- **Privacy policy URL:** https://github.com/Josephhamze/folio/blob/main/PRIVACY.md
- **Copyright:** 2026 Joseph Hamze
- **What's New** (1.0): First release on iPhone and iPad.

### Description

Folio is a PDF editor for iPhone and iPad. No account, no subscription, no ads.

MARK UP
• Highlight, underline and strike through text with a finger or Apple Pencil.
• Add notes, text boxes, rectangles, ovals, lines, arrows and freehand ink, in any colour.
• Tap a mark to select it, then drag it or delete it. A signature or note you place stays selected, ready to drag into place. Every change can be undone.

TEXT THAT MATCHES
• Tap with the Text Box tool and type. The text takes the font, size and colour of the nearest text on the page, so it looks typed into the document.
• Fix a line of text by typing over it.

SIGN
• Draw or type your signature and initials once, then place them with a tap.
• They're saved as vector outlines, so they stay sharp at any zoom and in other PDF apps.

FILL IN FORMS
• Type into a PDF's form fields.

READ
• Thumbnails, bookmarks and every comment, in a column beside the page on iPad.
• Find counts the matches and steps through them.
• Each file reopens at the page you left it on.
• Folio asks for a protected file's password, and respects its author's editing restrictions.

PRIVATE
• Folio collects nothing and makes no network connections. Your files stay where you keep them: on your device, in iCloud Drive or in any other Files location.

On iPad, the keyboard works too: ⌘F finds, ⌘Z undoes and ⌘P prints.

Folio is free and open source, and there's a version for the Mac as well.

## App Store Connect's questions

- **App Privacy:** Data Not Collected.
- **Encryption:** none beyond Apple's own. `ITSAppUsesNonExemptEncryption` is `NO` in `iOS/Info.plist`, so builds don't ask.
- **Age rating:** None for every question, which gives 4+.
- **Content rights:** no third-party content.
- **Availability:** every country or region except China mainland, which needs an ICP filing.
- **iPhone and iPad apps on Apple Silicon Macs:** off, since the Mac has its own Folio.
- **App Review notes:** No sign-in. Tap + in the document browser for a blank PDF, or open any PDF from Files.
