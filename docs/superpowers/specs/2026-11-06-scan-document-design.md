# Scan Document

The owner asked for a scan feature that scans documents perfectly. Folio could scan already, but only from Organize Pages › Insert Pages, onto pages of the system's paper size with margins round the scan, and it left reading the words to Tools › Recognize Text.

## What it does

- **Scan Document** on the launch screen scans paper into a new PDF. The launch screen shows two buttons and folds any more into More…, so where there's a camera, Scan Document takes the place of Create Document. The Create Document tile among the files still makes a blank document. Where there's no camera, as in the simulator, the launch screen keeps Create Document.
- The scanner is Apple's document camera (VisionKit's `VNDocumentCameraViewController`), shown full screen: it finds the page's edges, takes it once it's steady, straightens it and cleans it up. Each page can be retaken, cropped, turned or filtered (colour, greyscale, black and white, photo) before Save.
- A scan is the paper itself, so each page takes the scan's own shape, the biggest that fits the system's paper size (A4 or Letter), filled to its edges, and turned landscape for a wide scan. A receipt makes a long, narrow page and a business card a wide one, with no white margin. The picture is kept at no more than 300 dpi, as a JPEG.
- Folio reads the words on the scanned pages as they go in, on the device, with Recognize Text's reading: English, French, Chinese and many other languages. They go under the pages as invisible text, so Find finds them and they can be selected and copied. A pill shows how far it's got, and Folio then says on how many pages it read words.
- **Scan Pages…** (Organize Pages › Insert Pages, and the Pages menu on iPad) goes the same way: the scanned pages go in after the target pages, words read, as one undo step, and stay selected.
- On the Mac, File › Import from iPhone or iPad (Continuity Camera) goes in the same way, so a scan from an iPhone has its words read too. Pages that have text already, such as a typed PDF, are left as they are.

## How it's made

- iOS 26 runs a `NewDocumentButton`'s closure: Scan Document shows the scanner over the launch screen, Cancel makes no document, and the new document opens showing the scan, then reads its words.
- iOS 27 runs no button's closure; SwiftUI makes a blank document and opens it. Folio tells which button made it from the document browser's `activeDocumentCreationIntent`, as for Create from Photos. Scan Document is the `contentType: .pdf` form there, so its intent names the PDF type ("SwiftUIcom.adobe.pdf-0") while Create from Photos' names Folio's document type ("SwiftUIFolio.FolioDocument-0"). The new document shows the scanner, and the scan, words read, takes the blank page's place. Cancel leaves the blank document, as Create from Photos does.
- The scanner and Photos' picker are each shown over whatever is on top of the key window, for one call to wait on. That replaces the SwiftUI full-screen cover Scan Pages… had.

## Testing

- A unit test (Mac) checks a scan's page shape for a tall and a wide scan, that the scan fills its page, and that its words are found after it goes in, as one undo step, in either place.
- The camera doesn't run in the simulator. A probe build with the button forced on checked, on iOS 26.2 and 27.2 simulators, which intent each button gives and that the scanner shows and cancels from the launch screen and from a new document.
