// Frames the App Store's screenshots for the listing: each on Folio's red, under a line that says what it shows, at the
// screenshot's own size, which is the one App Store Connect asks for. `./build.sh screenshots` runs it, as
// `swift icon/app-store.swift`, on build/app-store/*.png, into build/app-store/listing.
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

/// What each of testScreenshots' shots shows, by the shot's name.
let captions = [
    "1 Mark up": ("Mark up any PDF", "Highlight, write and draw with a finger or Apple Pencil"),
    "2 Sign": ("Sign in seconds", "Draw or type your signature once, then place it with a tap"),
    "3 Pages": ("Every page at hand", "Thumbnails, bookmarks and every comment"),
    "4 Organize": ("Put pages in order", "Reorder, rotate, insert, extract and split"),
    "5 Protect": ("Keep it private", "Passwords, restrictions and real redactions"),
]

/// The screenshot in a dark bezel on the icon's red, running off the bottom, under its title and subtitle.
struct Listing: View {
    let shot: NSImage, size: CGSize, title: String, subtitle: String

    var body: some View {
        // An iPad's screen is nearly square and a phone's tall, so on an iPad the words are sized to less of the width.
        let pad = size.width / size.height > 0.6, unit = size.width * (pad ? 0.7 : 1)
        let width = size.width * (pad ? 0.78 : 0.8), bezel = width * (pad ? 0.012 : 0.022)
        let radius = width * (pad ? 0.035 : 0.13)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0xE5484D), Color(hex: 0x9E1B25)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: unit * 0.025) {
                Text(title).font(.system(size: unit * 0.085, weight: .bold))
                Text(subtitle).font(.system(size: unit * 0.042, weight: .medium)).opacity(0.85)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, size.width * 0.08)
            .padding(.top, size.height * 0.06)
            Image(nsImage: shot).resizable().aspectRatio(contentMode: .fit)
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: radius - bezel, style: .continuous))
                .padding(bezel)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(hex: 0x1C1C1E)))
                .shadow(color: .black.opacity(0.35), radius: unit * 0.03, y: unit * 0.015)
                .padding(.top, size.height * 0.25)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }
}

MainActor.assumeIsolated {
    let shots = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../build/app-store")
    let listing = shots.appendingPathComponent("listing")
    try? FileManager.default.removeItem(at: listing)
    try! FileManager.default.createDirectory(at: listing, withIntermediateDirectories: true)
    for file in try! FileManager.default.contentsOfDirectory(at: shots, includingPropertiesForKeys: nil) where file.pathExtension == "png" {
        // Named "<simulator> - <shot>.png" by build.sh.
        let name = file.deletingPathExtension().lastPathComponent.components(separatedBy: " - ").last!
        guard let caption = captions[name], let image = NSImage(contentsOf: file), let pixels = image.representations.first else {
            print("No caption for \(file.lastPathComponent)")
            continue
        }
        let size = CGSize(width: pixels.pixelsWide, height: pixels.pixelsHigh)
        let renderer = ImageRenderer(content: Listing(shot: image, size: size, title: caption.0, subtitle: caption.1))
        renderer.scale = 1
        renderer.isOpaque = true   // App Store Connect refuses transparency
        try! NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: listing.appendingPathComponent(file.lastPathComponent))
    }
}
