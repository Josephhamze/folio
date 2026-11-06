import CoreImage
import PDFKit
import simd
import Vision
#if os(iOS)
import AVFoundation
import SwiftUI
#endif

/// How a scan's pages are cleaned up: the paper evened out to white and the print darkened and sharpened, as a copier
/// would, in colour, in greys or in black and white; or the page as the camera saw it, for a photo.
enum ScanLook: CaseIterable, Identifiable {
    case colour, greyscale, blackAndWhite, photo

    var id: Self { self }

    var name: String {
        switch self {
        case .colour: String(localized: "Colour")
        case .greyscale: String(localized: "Greyscale")
        case .blackAndWhite: String(localized: "Black & White")
        case .photo: String(localized: "Photo")
        }
    }
}

/// A photo of a page being scanned, where the paper's corners are in it, and how far it's turned: all it takes to make
/// the page again when they change.
struct ScanShot {
    /// Upright, as it was taken.
    let photo: CIImage
    /// The paper's top left, top right, bottom right and bottom left corners, in the photo's space, from its bottom left.
    var corners: [CGPoint]
    /// Quarter turns clockwise.
    var turns = 0

    /// Each page is drawn once, from a 12 megapixel photo: keeping what's worked out on the way takes memory for nothing.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// The photo, with the paper's corners where Vision finds them, or else the photo's own.
    init(photo: CIImage) {
        self.photo = photo
        let box = photo.extent
        corners = Self.paper(in: VNImageRequestHandler(ciImage: photo))?.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
            ?? Self.corners(of: box)
    }

    /// A box's top left, top right, bottom right and bottom left corners, the order the paper's are kept in.
    static func corners(of box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.minY)]
    }

    /// Whether corners make a shape a page could be cropped to: going round one way, none bent back in, which also leaves
    /// room for a page.
    static func isPage(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        let bends = (0..<4).map { i in
            let (a, b, c) = (corners[i], corners[(i + 1) % 4], corners[(i + 2) % 4])
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        return bends.allSatisfy { $0 > 0 } || bends.allSatisfy { $0 < 0 }
    }

    /// Where the paper's corners are in a picture, as Vision finds them, each as a share of its width and height from its
    /// bottom left, in the order they're kept: none where it finds no paper.
    static func paper(in picture: VNImageRequestHandler) -> [CGPoint]? {
        let request = VNDetectDocumentSegmentationRequest()
        guard (try? picture.perform([request])) != nil, let found = request.results?.first, found.confidence > 0.5 else { return nil }
        return [found.topLeft, found.topRight, found.bottomRight, found.bottomLeft]
    }

    /// The paper straightened out of the photo, in its own shape, and turned, no finer than 300 dpi on the page it fills,
    /// cleaned up in this look, on white.
    func picture(_ look: ScanLook) -> CIImage {
        let flat = photo.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: corners[0]), "inputTopRight": CIVector(cgPoint: corners[1]),
            "inputBottomRight": CIVector(cgPoint: corners[2]), "inputBottomLeft": CIVector(cgPoint: corners[3])])
        let box = flat.extent, width = (shape ?? box.width / box.height) * box.height
        let size = FolioDocument.scanSize(CGSize(width: width, height: box.height))
        let scale = min(1, max(size.width, size.height) * 300 / 72 / max(width, box.height, 1))
        let fine = flat.transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY)).clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: width / box.width])
            .cropped(to: CGRect(x: 0, y: 0, width: (width * scale).rounded(), height: (box.height * scale).rounded()))
            .oriented([.up, .right, .down, .left][turns % 4])
        let page = fine.transformed(by: CGAffineTransform(translationX: -fine.extent.minX, y: -fine.extent.minY))
        return (look == .photo ? page : cleaned(page, look)).composited(over: CIImage(color: .white)).cropped(to: page.extent)
    }

    /// The paper's width over its height, worked out from where its corners are in the photo: a slanted view squeezes it,
    /// which straightening alone keeps. Taken as by the main lens, its centre on the photo's, at a focal length of 0.72 of
    /// the photo's longer side. Nil for corners that make no rectangle. (Zhang and He, "Whiteboard scanning and image
    /// enhancement", 2007.)
    private var shape: CGFloat? {
        let box = photo.extent, focal = 0.72 * max(box.width, box.height)
        // As seen from the lens.
        let m = corners.map { SIMD3<Double>(Double(($0.x - box.midX) / focal), Double(($0.y - box.midY) / focal), 1) }
        let (topLeft, topRight, bottomRight, bottomLeft) = (m[0], m[1], m[2], m[3])
        let across = dot(cross(topLeft, bottomRight), bottomLeft) / dot(cross(topRight, bottomRight), bottomLeft) * topRight - topLeft
        let down = dot(cross(topLeft, bottomRight), topRight) / dot(cross(bottomLeft, bottomRight), topRight) * bottomLeft - topLeft
        let squared = length_squared(across) / length_squared(down)
        return squared.isFinite && squared > 0 ? CGFloat(squared.squareRoot()) : nil
    }

    /// The paper evened out to white wherever it's lit, by dividing out its light, as a copier's scan is, and the print
    /// darkened and sharpened.
    private func cleaned(_ image: CIImage, _ look: ScanLook) -> CIImage {
        let page = image.clampedToExtent()
        // The paper's light: the print taken out by the brightest nearby, then the darkest of that nearby, which puts back
        // a shadow's edge where it was, smoothed, worked out at a quarter the size for speed. In each colour, no darker
        // than a third of the brightest paper's, so a dark picture on the page isn't taken for paper in shadow, while the
        // paper under a hand's shadow, which can more than halve the light, is.
        let light = page.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .applyingGaussianBlur(sigma: 1.5)
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 8])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 8])
            .applyingGaussianBlur(sigma: 10)
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let floor = Self.brightest(light.cropped(to: image.extent))
        let even = light.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: floor[0] / 3, y: floor[1] / 3, z: floor[2] / 3, w: 0)])
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: page])
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5, kCIInputIntensityKey: 0.6])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: look == .colour ? 1 : 0])
            .cropped(to: image.extent)
        // Paper evened out comes to about 1, and print well under: white from just under the paper's, black well into the
        // print, or for black and white, a narrow step between.
        return look == .blackAndWhite ? Self.levels(even, black: 0.5, white: 0.72) : Self.levels(even, black: 0.3, white: 0.88)
    }

    /// The brightest of each of the picture's colours.
    private static func brightest(_ image: CIImage) -> [CGFloat] {
        var pixel: [Float] = [0, 0, 0, 0]
        context.render(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]), toBitmap: &pixel,
                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return pixel.map { CGFloat($0) }
    }

    /// Black from `black` down and white from `white` up, the values between stretched to fill.
    private static func levels(_ image: CIImage, black: CGFloat, white: CGFloat) -> CIImage {
        let gain = 1 / (white - black), shift = -black * gain
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputBiasVector": CIVector(x: shift, y: shift, z: shift, w: 0)])
            .applyingFilter("CIColorClamp")
    }

    /// The page the shot makes in this look, of the paper's shape, filled by its picture kept as a JPEG, with the words
    /// Vision reads on it under it; and a small picture of it to show.
    func made(_ look: ScanLook) async -> (page: PDFPage, preview: CGImage)? {
        let image = picture(look)
        guard let picture = Self.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              let page = FolioDocument.page(scanned: picture, text: (try? await recognize(picture)) ?? []) else { return nil }
        // The preview kept as a JPEG, as the page is, takes a fraction of the memory: a scan can run to many pages.
        return (page, Self.preview(CIImage(cgImage: picture), side: 1200).flatMap(asJPEG) ?? picture)
    }

    /// The picture shrunk to fit a square this many pixels a side, to show.
    static func preview(_ image: CIImage, side: CGFloat) -> CGImage? {
        let scale = min(1, side / max(image.extent.width, image.extent.height, 1))
        let small = image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        return context.createCGImage(small, from: CGRect(x: image.extent.minX * scale, y: image.extent.minY * scale,
                                                         width: (image.extent.width * scale).rounded(), height: (image.extent.height * scale).rounded()))
    }
}

/// When the scanner takes the paper it sees: once it's held still for a moment, and not again until it moves on, to the
/// next page, or out of view.
struct Steadiness {
    private var still: (corners: [CGPoint], since: Date)?
    private var taken: [CGPoint]?

    /// Takes where the paper's corners are as the camera sees them now, as shares of the picture, nil for no paper, and
    /// says whether to take it.
    mutating func see(_ corners: [CGPoint]?, at now: Date) -> Bool {
        guard let corners else {
            (still, taken) = (nil, nil)
            return false
        }
        if let taken, Self.apart(corners, taken) < 0.1 { return false }
        taken = nil
        guard let still, Self.apart(corners, still.corners) < 0.02 else {
            self.still = (corners, now)
            return false
        }
        guard now.timeIntervalSince(still.since) >= 0.8 else { return false }
        (self.still, taken) = (nil, corners)
        return true
    }

    /// The furthest any corner is from its place in the other, as a share of the picture.
    private static func apart(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    }
}

#if os(iOS)
/// Folio's scanner: the camera, outlining the paper it sees and taking it once it's held still, then straightening each
/// page, cleaning it up and reading its words while the next is scanned. Its pages can be cropped, turned, cleaned up
/// another way or deleted before they're saved. It's shown full screen over whatever is on screen, for one call to wait
/// on, as Photos' picker is: Scan Document over the launch screen, or on iOS 27 as the new document opens, and Organize
/// Pages to insert a scan.
@MainActor @Observable final class Scanner {
    /// Whether there's a camera to scan with: the simulator has none.
    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }
    private static var isScanning = false

    /// The pages scanned, in order, their words read: none for Cancel, or when the camera can't be used.
    static func scan() async -> [PDFPage] {
        guard isAvailable, !isScanning, let top = topController() else { return [] }
        isScanning = true
        defer { isScanning = false }
        let scanner = Scanner()
        return await withCheckedContinuation { done in
            scanner.done = done
            let host = ScannerHost(rootView: ScannerView(scanner: scanner))
            host.modalPresentationStyle = .fullScreen
            scanner.host = host
            top.present(host, animated: true)
            // UIKit drops a presentation over one still coming or going, as a new document can be on iOS 27.
            if host.presentingViewController == nil {
                scanner.done = nil
                done.resume(returning: [])
            }
        }
    }

    /// A page scanned: its shot, and once made, its page and a small picture of it.
    struct Page: Identifiable {
        let id = UUID()
        var shot: ScanShot
        var made: (page: PDFPage, preview: CGImage)?
    }

    enum State { case starting, running, denied, failed }

    private(set) var pages: [Page] = []
    private(set) var look = ScanLook.colour
    var auto = true
    private(set) var light = false
    /// Where the paper's corners are in what the camera sees now, upright, as shares of the picture from its bottom left.
    private(set) var seen: [CGPoint]?
    private(set) var state = State.starting
    var reviewing = false
    /// Photos taken, to flash for each.
    private(set) var shots = 0
    /// A photo being taken, which Save waits for.
    private(set) var taking = false
    private(set) var finishing = false

    @ObservationIgnored let camera = Camera()
    @ObservationIgnored private var steadiness = Steadiness()
    @ObservationIgnored private var making: Task<Void, Never>?
    @ObservationIgnored private var done: CheckedContinuation<[PDFPage], Never>?
    @ObservationIgnored private weak var host: UIViewController?
    @ObservationIgnored private weak var preview: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var turning: NSKeyValueObservation?

    /// Asks for the camera the first time, then starts it. The screen appears again as the pages to review go, and the
    /// camera is started only once.
    func start() async {
        guard state == .starting else { return }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return state = .denied }
        camera.saw = { [weak self] in self?.see($0) }
        camera.took = { [weak self] in self?.add($0) }
        state = await camera.start() ? .running : .failed
        // The preview has a connection to turn only now.
        turnPreview()
    }

    /// Follows the preview, turning it level as the device turns.
    func watch(_ preview: AVCaptureVideoPreviewLayer) {
        guard let device = camera.device else { return }
        self.preview = preview
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: preview)
        turning = rotation?.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in MainActor.assumeIsolated { self?.turnPreview() } }
        turnPreview()
    }

    private func turnPreview() {
        guard let angle = rotation?.videoRotationAngleForHorizonLevelPreview else { return }
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        camera.turn(angle)
    }

    private func see(_ corners: [CGPoint]?) {
        seen = corners
        if steadiness.see(corners, at: .now), auto, !reviewing { take() }
    }

    /// Takes a photo, level as the device is held.
    func take() {
        guard state == .running, !taking, !finishing else { return }
        taking = true
        shots += 1
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.takePhoto(at: rotation?.videoRotationAngleForHorizonLevelCapture ?? 90)
    }

    private func add(_ shot: ScanShot?) {
        taking = false
        guard let shot else { return }
        pages.append(Page(shot: shot))
        remake(pages[pages.count - 1].id)
    }

    /// Makes the page again, off the main thread, after those before it: one at a time, as each takes a fair amount of
    /// memory.
    private func remake(_ id: Page.ID) {
        let before = making
        making = Task {
            await before?.value
            guard let shot = pages.first(where: { $0.id == id })?.shot else { return }
            let look = look
            let made = await Task.detached(priority: .userInitiated) { await shot.made(look) }.value
            if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].made = made }
        }
    }

    func change(look: ScanLook) {
        self.look = look
        for page in pages { remake(page.id) }
    }

    func crop(_ id: Page.ID, to corners: [CGPoint]) { edit(id) { $0.corners = corners } }

    func turn(_ id: Page.ID) { edit(id) { $0.turns += 1 } }

    private func edit(_ id: Page.ID, _ change: (inout ScanShot) -> Void) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        change(&pages[i].shot)
        remake(id)
    }

    func delete(_ id: Page.ID) { pages.removeAll { $0.id == id } }

    func switchLight() {
        light.toggle()
        camera.light(light)
    }

    /// Puts the scanner away, with the pages scanned once they're made, or none for Cancel.
    func finish(saving: Bool) {
        guard !finishing else { return }
        finishing = true
        Task {
            if saving { await making?.value }
            camera.stop()
            let made = saving ? pages.compactMap(\.made?.page) : []
            let done = done
            self.done = nil
            if let presenter = host?.presentingViewController {
                presenter.dismiss(animated: true) { done?.resume(returning: made) }
            } else {
                done?.resume(returning: made)
            }
        }
    }
}

/// The back camera, for the scanner: where the paper's corners are in what it sees, ten times a second, and the pages it
/// photographs, each told on the main thread. It works on a queue of its own.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// The main lens, as part of a set where it's in one, which switches to the wide lens for a page held close.
    let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
                                                  mediaType: .video, position: .back).devices.first
    /// Hears where the paper's corners are in each picture looked at, upright, as shares of it from its bottom left: nil
    /// for no paper.
    @MainActor var saw: ([CGPoint]?) -> Void = { _ in }
    /// Hears each page photographed, with where its paper is: nil when the photo failed.
    @MainActor var took: (ScanShot?) -> Void = { _ in }
    private let photos = AVCapturePhotoOutput()
    private let frames = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "Folio camera")
    /// How the camera's pictures are turned from upright, as the preview turns them.
    private var orientation = CGImagePropertyOrientation.right
    private var looked = Date.distantPast

    /// Sets the camera up and starts it: false where it can't be.
    func start() async -> Bool {
        await withCheckedContinuation { done in queue.async { done.resume(returning: self.configure()) } }
    }

    private func configure() -> Bool {
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        let fits = session.canAddInput(input) && session.canAddOutput(photos) && session.canAddOutput(frames)
        if fits {
            session.addInput(input)
            session.addOutput(photos)
            session.addOutput(frames)
            frames.alwaysDiscardsLateVideoFrames = true
            frames.setSampleBufferDelegate(self, queue: queue)
            photos.maxPhotoQualityPrioritization = .quality
        }
        session.commitConfiguration()
        guard fits else { return false }
        // The biggest photo up to 12 megapixels: past 300 dpi for a page that fills it, and quick to take. The preset's
        // format is the device's only once committed.
        let pixels = { (size: CMVideoDimensions) in Int(size.width) * Int(size.height) }
        if let size = device.activeFormat.supportedMaxPhotoDimensions.filter({ pixels($0) <= 12_600_000 }).max(by: { pixels($0) < pixels($1) }) {
            photos.maxPhotoDimensions = size
        }
        if (try? device.lockForConfiguration()) != nil {
            // A set of lenses starts at its widest: start at the main one instead.
            if let main = device.virtualDeviceSwitchOverVideoZoomFactors.first { device.videoZoomFactor = CGFloat(truncating: main) }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
        session.startRunning()
        return session.isRunning
    }

    func stop() {
        light(false)
        queue.async { self.session.stopRunning() }
    }

    /// Reads the camera's pictures turned as the preview is, by this many degrees clockwise.
    func turn(_ angle: CGFloat) {
        queue.async { self.orientation = [.up, .right, .down, .left][(Int((angle / 90).rounded()) % 4 + 4) % 4] }
    }

    func light(_ on: Bool) {
        queue.async {
            guard let device = self.device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Ten looks a second follow a hand well enough, and spare the battery.
        guard let frame = sampleBuffer.imageBuffer, Date.now.timeIntervalSince(looked) >= 0.1 else { return }
        looked = .now
        let corners = ScanShot.paper(in: VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation))
        Task { @MainActor in saw(corners) }
    }

    /// Photographs the page, level at this many degrees clockwise.
    func takePhoto(at angle: CGFloat) {
        queue.async { [self] in
            guard session.isRunning else {
                Task { @MainActor in took(nil) }
                return
            }
            if let connection = photos.connection(with: .video), connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = photos.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            photos.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let shot = photo.fileDataRepresentation().flatMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }.map(ScanShot.init)
        Task { @MainActor in took(shot) }
    }
}

/// The scanner's screen, kept upright on a phone, as the Camera app's is.
private final class ScannerHost: UIHostingController<ScannerView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { traitCollection.userInterfaceIdiom == .phone ? .portrait : .all }
}

private struct ScannerView: View {
    @Bindable var scanner: Scanner
    @State private var discarding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Button("Cancel") { if scanner.pages.isEmpty { scanner.finish(saving: false) } else { discarding = true } }
                    .confirmationDialog("Discard Scanned Pages", isPresented: $discarding) {
                        Button("Discard Scanned Pages", role: .destructive) { scanner.finish(saving: false) }
                    }
                Spacer()
                if scanner.camera.device?.hasTorch == true {
                    Button("Light", systemImage: scanner.light ? "flashlight.on.fill" : "flashlight.off.fill") { scanner.switchLight() }
                        .labelStyle(.iconOnly)
                }
                LookMenu(scanner: scanner)
                Button(scanner.auto ? "Auto" : "Manual") { scanner.auto.toggle() }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            ZStack {
                CameraView(scanner: scanner)
                VStack {
                    if let hint { Text(hint).font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.6), in: .capsule) }
                    Spacer()
                }
                .padding(.top, 14)
                if scanner.state == .denied {
                    VStack(spacing: 14) {
                        Text("Allow Folio to use the camera in Settings to scan").multilineTextAlignment(.center)
                        Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }.buttonStyle(.borderedProminent)
                    }
                    .padding(32)
                }
                Color.white.allowsHitTesting(false)
                    .phaseAnimator([0, 0.7], trigger: scanner.shots) { $0.opacity($1) } animation: { $0 == 0 ? .easeOut(duration: 0.3) : .linear(duration: 0.04) }
            }
            HStack {
                Button { scanner.reviewing = true } label: { Thumbnail(page: scanner.pages.last, count: scanner.pages.count) }
                    .frame(width: 72, alignment: .leading)
                    .disabled(scanner.pages.isEmpty)
                    .accessibilityLabel("Scanned Pages")
                Spacer()
                Button(action: scanner.take) {
                    Circle().fill(.white).frame(width: 62, height: 62).padding(6).overlay(Circle().stroke(.white, lineWidth: 4))
                }
                .disabled(scanner.state != .running)
                .accessibilityLabel("Take Photo")
                Spacer()
                SaveButton(scanner: scanner).frame(width: 72, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .frame(height: 112)
        }
        .foregroundStyle(.white)
        .background(.black)
        // Save takes the pages as they are.
        .disabled(scanner.finishing)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .fullScreenCover(isPresented: $scanner.reviewing) { ReviewView(scanner: scanner) }
        .task { await scanner.start() }
    }

    private var hint: String? {
        switch scanner.state {
        case .running: scanner.seen == nil ? String(localized: "Point the camera at a page") : scanner.auto ? String(localized: "Hold still") : nil
        case .failed: String(localized: "The camera is unavailable")
        case .starting, .denied: nil
        }
    }
}

/// How the pages are cleaned up, to pick another.
private struct LookMenu: View {
    let scanner: Scanner

    var body: some View {
        Menu {
            Picker("Look", selection: Binding(get: { scanner.look }, set: { scanner.change(look: $0) })) {
                ForEach(ScanLook.allCases) { Text($0.name).tag($0) }
            }
        } label: {
            Label(scanner.look.name, systemImage: "camera.filters")
        }
    }
}

/// Save, or while the pages are being made for it, a spinner.
private struct SaveButton: View {
    let scanner: Scanner

    var body: some View {
        if scanner.finishing {
            ProgressView()
        } else {
            Button("Save") { scanner.finish(saving: true) }
                .fontWeight(.semibold)
                .disabled(scanner.pages.isEmpty || scanner.taking)
        }
    }
}

/// The last page scanned, small, with how many there are.
private struct Thumbnail: View {
    let page: Scanner.Page?
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let page {
                Group {
                    if let preview = page.made?.preview {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 48, height: 64)
                Text(count, format: .number).font(.caption2.bold()).padding(5).background(.tint, in: .circle).offset(x: 10, y: -10)
            }
        }
    }
}

/// What the camera sees, with the paper it finds outlined.
private struct CameraView: UIViewRepresentable {
    let scanner: Scanner

    func makeUIView(context: Context) -> CameraPreview {
        let view = CameraPreview()
        view.preview.session = scanner.camera.session
        scanner.watch(view.preview)
        return view
    }

    func updateUIView(_ view: CameraPreview, context: Context) { view.outline(scanner.seen) }
}

private final class CameraPreview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let paper = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.videoGravity = .resizeAspect
        paper.lineWidth = 3
        paper.lineJoin = .round
        layer.addSublayer(paper)
    }

    required init?(coder: NSCoder) { nil }

    /// Outlines the paper at these corners, upright, as shares of the picture from its bottom left: nothing for nil.
    func outline(_ corners: [CGPoint]?) {
        paper.strokeColor = tintColor.cgColor
        paper.fillColor = tintColor.withAlphaComponent(0.25).cgColor
        guard let corners else { return paper.path = nil }
        let picture = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let path = CGMutablePath()
        path.addLines(between: corners.map { CGPoint(x: picture.minX + $0.x * picture.width, y: picture.maxY - $0.y * picture.height) })
        path.closeSubpath()
        paper.path = path
    }
}

/// The pages scanned so far, one at a time, to crop, turn, clean up another way or delete.
private struct ReviewView: View {
    let scanner: Scanner
    @State private var shown: Scanner.Page.ID?
    @State private var cropping = false

    var body: some View {
        NavigationStack {
            TabView(selection: $shown) {
                ForEach(scanner.pages) { page in
                    Group {
                        if let preview = page.made?.preview {
                            Image(decorative: preview, scale: 1).resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .padding()
                    .tag(Optional(page.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(.black)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { scanner.reviewing = false } }
                ToolbarItem(placement: .confirmationAction) { SaveButton(scanner: scanner) }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Crop", systemImage: "crop") { cropping = true }
                    Spacer()
                    Button("Rotate", systemImage: "rotate.right") { if let shown { scanner.turn(shown) } }
                    Spacer()
                    LookMenu(scanner: scanner)
                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive) { delete() }
                }
                .labelStyle(.iconOnly)
                .font(.title3)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
            .fullScreenCover(isPresented: $cropping) {
                if let page = scanner.pages.first(where: { $0.id == shown }) { CropView(scanner: scanner, page: page) }
            }
        }
        .disabled(scanner.finishing)
        .environment(\.colorScheme, .dark)
        // It appears again as Crop goes, on the page cropped.
        .onAppear { if shown == nil { shown = scanner.pages.last?.id } }
    }

    private var title: String {
        let at = scanner.pages.firstIndex { $0.id == shown } ?? 0
        return String(localized: "\(at + 1) of \(scanner.pages.count)")
    }

    private func delete() {
        guard let at = scanner.pages.firstIndex(where: { $0.id == shown }) else { return }
        scanner.delete(scanner.pages[at].id)
        if scanner.pages.isEmpty { return scanner.reviewing = false }
        shown = scanner.pages[min(at, scanner.pages.count - 1)].id
    }
}

/// A page's photo, with its paper's corners to drag where they should be, magnified above the finger as one moves.
private struct CropView: View {
    let scanner: Scanner
    let page: Scanner.Page
    @State private var corners: [CGPoint] = []
    @State private var photo: CGImage?
    /// The corner being dragged, and where it was on screen as the drag began.
    @State private var dragging: (corner: Int, from: CGPoint)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { space in
                let extent = page.shot.photo.extent
                let box = AVMakeRect(aspectRatio: extent.size, insideRect: CGRect(origin: .zero, size: space.size).insetBy(dx: 28, dy: 28))
                // From the photo's space, from its bottom left, to the view's, from its top left, and back, kept on the photo.
                let shown = { (p: CGPoint) in
                    CGPoint(x: box.minX + (p.x - extent.minX) / extent.width * box.width, y: box.maxY - (p.y - extent.minY) / extent.height * box.height)
                }
                let placed = { (p: CGPoint) in
                    CGPoint(x: extent.minX + (min(max(p.x, box.minX), box.maxX) - box.minX) / box.width * extent.width,
                            y: extent.minY + (box.maxY - min(max(p.y, box.minY), box.maxY)) / box.height * extent.height)
                }
                ZStack {
                    if let photo { Image(decorative: photo, scale: 1).resizable().frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY) }
                    if corners.count == 4 {
                        // The photo outside the paper dimmed.
                        Path { $0.addRect(box); $0.addLines(corners.map(shown)); $0.closeSubpath() }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                        Path { $0.addLines(corners.map(shown)); $0.closeSubpath() }.stroke(.tint, lineWidth: 2)
                        ForEach(0..<4, id: \.self) { i in
                            ZStack {
                                Circle().fill(.white.opacity(0.3))
                                Circle().strokeBorder(.tint, lineWidth: 3)
                            }
                            .frame(width: 40, height: 40)
                            .contentShape(.circle.inset(by: -8))
                            // The corner moves as far as the finger does, not to under it.
                            .gesture(DragGesture(coordinateSpace: .named("photo"))
                                .onChanged { drag in
                                    let from = dragging?.from ?? shown(corners[i])
                                    dragging = (i, from)
                                    corners[i] = placed(CGPoint(x: from.x + drag.translation.width, y: from.y + drag.translation.height))
                                }
                                .onEnded { _ in dragging = nil })
                            .position(shown(corners[i]))
                        }
                        // What's under the finger, three times the size, above it, or below it near the top.
                        if let photo, let i = dragging?.corner {
                            let at = shown(corners[i]), zoom: CGFloat = 3
                            Image(decorative: photo, scale: 1).resizable()
                                .frame(width: box.width * zoom, height: box.height * zoom)
                                .offset(x: (box.midX - at.x) * zoom, y: (box.midY - at.y) * zoom)
                                .frame(width: 120, height: 120)
                                .clipShape(.circle)
                                .overlay { Circle().fill(.tint).frame(width: 6, height: 6) }
                                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                                .position(x: min(max(at.x, 64), space.size.width - 64), y: at.y > 160 ? at.y - 110 : at.y + 110)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .coordinateSpace(.named("photo"))
            }
            .background(.black)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        scanner.crop(page.id, to: corners)
                        dismiss()
                    }
                    .disabled(!ScanShot.isPage(corners))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Whole Photo") { corners = ScanShot.corners(of: page.shot.photo.extent) }.padding(.bottom, 12)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { corners = page.shot.corners }
        .task {
            let photo = page.shot.photo
            self.photo = await Task.detached { ScanShot.preview(photo, side: 1600) }.value
        }
    }
}
#endif
