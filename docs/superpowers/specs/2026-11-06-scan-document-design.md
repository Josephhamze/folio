# Scan Document

The owner asked for a scan feature that scans documents perfectly. The first version used Apple's document scanner (VisionKit's `VNDocumentCameraViewController`). Tried on a phone, the owner found its scans poor on every count asked about: blurry text, dull or grey paper, the camera and crop, and the steps around it. Folio's side kept the 300 dpi the scanner gave, so the scanner itself had to go: Folio now has its own.

## What it does

- **Scan Document** on the launch screen scans paper into a new PDF. The launch screen shows two buttons and folds any more into More…, so where there's a camera, Scan Document takes the place of Create Document. The Create Document tile among the files still makes a blank document. Where there's no camera, as in the simulator, the launch screen keeps Create Document.
- **The camera** fills the screen. Folio outlines the paper it sees, about ten times a second, and takes it once it's been held still for 0.8 seconds. It doesn't take the same page again until the paper moves on or leaves the view. Auto can be switched to Manual; the shutter works either way. A light button switches on the torch.
- **Sharp text.** Photos are taken at up to 12 megapixels, which is past 300 dpi for a page that fills the view, with quality first. Where the phone has a set of lenses, Folio starts at the main one, and the set switches to the wide lens for a page held close, as the Camera app's macro does.
- **The paper's own shape.** Folio finds the paper's corners in the photo with Vision and straightens the page. Straightening alone keeps the squeeze of a slanted view, so Folio works out the paper's true width over its height from the corners, as a camera at the main lens's focal length would see them (Zhang and He, 2007). An A4 page held at a slant comes out A4. Each page is the biggest of its shape that fits the system's paper size, so a receipt is long and narrow and a business card wide.
- **Clean paper.** Folio works out the paper's light, taking the print out with the brightest nearby and smoothing it, and divides it out. The paper is then white wherever it's lit, shadows included, and the print keeps its weight, unlike Core Image's document enhancer, which thinned it. The light is never taken to be under half the brightest paper's, so a dark picture on the page stays dark. The print is then sharpened and darkened. There are four looks: Colour (the default), Greyscale, Black & White, and Photo, which keeps the page as the camera saw it.
- **Words read as you go.** Each page is made off the main thread while the next is scanned: straightened, cleaned up, read by Vision, and kept as a JPEG of no more than 300 dpi with its words under it as invisible text. Save waits only for what's left, so the document opens with its words already found, with no "Recognizing text" wait.
- **Before saving**, the thumbnail opens the pages one at a time. Crop shows the photo with the corners to drag, and Whole Photo for the whole of it. Rotate turns a page, the look can be changed, and Delete removes it.
- **Scan Pages…** (Organize Pages › Insert Pages, and the Pages menu on iPad) opens the same scanner. Its pages go in after the target pages, as one undo step, and stay selected.
- On the Mac, File › Import from iPhone or iPad (Continuity Camera) still has its pages' words read as they go in.

## How it's made

- `Scanner.swift` holds the work done to a photo, `ScanShot`, which also builds on the Mac so it can be tested there; `Steadiness`, which decides when to take a photo; and, on iOS, the `Scanner`, its `Camera` and their views.
- iOS 26 runs a `NewDocumentButton`'s closure: Scan Document shows the scanner over the launch screen, Cancel makes no document, and the new document opens showing the scan, its words already read.
- iOS 27 runs no button's closure; SwiftUI makes a blank document and opens it. Folio tells which button made it from the document browser's `activeDocumentCreationIntent`: Scan Document is the `contentType: .pdf` form, so its intent names the PDF type. The new document is covered in black while the scanner opens over it, and the scan takes the blank page's place. Cancel leaves the blank document.
- The scanner is shown over whatever is on top of the key window, for one call to wait on, as Photos' picker is. It keeps to portrait on a phone, as the Camera app does. The preview turns with `AVCaptureDevice.RotationCoordinator`, and photos are taken level with the device.
- Folio asks for the camera the first time. If it's refused, the scanner says to allow it in Settings, with a button there.

## Testing

- Mac unit tests: a synthetic photo of an A4 page tilted 25° and turned 10°, through a pinhole camera, lit from one side, soft and grainy. Vision finds its corners, and the page comes out A4 within 1.5%. The paper in the shadow is white and the print dark, the blue signature stays blue and the black box black. Black & White has no colour left, and Photo keeps the shadow. Turned, the page lies on its side. The page made is A4 and its words can be found.
- A unit test walks `Steadiness` through holding still, moving, holding the same page, leaving the view and moving on.
- The camera doesn't run in the simulator. A probe build fed the scanner a synthetic photo to check, on the iOS 27.2 simulator, the screens and the steps from Scan Document to the saved document.
