// Frames the App Store's screenshots for the listing: each in a drawn iPhone or iPad on Folio's red, under a line that says
// what it shows, at the screenshot's own size, which is the one App Store Connect asks for. `./build.sh screenshots` runs it,
// as `swift icon/app-store.swift`, on build/app-store/*.png, into build/app-store/listing.
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

/// What each of testScreenshots' shots shows, by the shot's name: its title, the end of the title in the highlighter's
/// yellow, and a subtitle in two lines on an iPhone.
let captions = [
    "1 Mark up": ("Mark up", "any PDF", "Highlight, write and draw\nwith a finger or Apple Pencil"),
    "2 Sign": ("Sign", "in seconds", "Draw or type your signature once,\nthen place it with a tap"),
    "3 Start": ("PDFs from", "photos", "A page for each photo,\nin the order you pick them"),
    "4 Organize": ("Put pages", "in order", "Reorder, rotate, insert,\nextract and split"),
    "5 Protect": ("Keep it", "private", "Passwords, restrictions\nand real redactions"),
]

/// The screenshot in a drawn iPhone or iPad, on the icon's red lit from above, under its title and subtitle.
struct Listing: View {
    let shot: NSImage, size: CGSize, caption: (String, String, String)

    var body: some View {
        // An iPad's screen is nearly square and a phone's tall, so on an iPad the words are sized to less of the width.
        let pad = size.width / size.height > 0.6, unit = size.width * (pad ? 0.72 : 1)
        // The device, sized to the room under the words: its metal edge and black bezel are parts of its width, around a
        // screen of the screenshot's shape.
        let edgeShare: CGFloat = pad ? 0.006 : 0.011, bezelShare: CGFloat = pad ? 0.028 : 0.016, aspect = size.width / size.height
        let top = size.height * (pad ? 0.205 : 0.215), room = size.height * 0.965 - top
        let width = min(room / ((1 - 2 * edgeShare - 2 * bezelShare) / aspect + 2 * edgeShare + 2 * bezelShare), size.width * 0.84)
        let edge = width * edgeShare, bezel = width * bezelShare, left = (size.width - width) / 2
        let screen = CGSize(width: width - 2 * (edge + bezel), height: (width - 2 * (edge + bezel)) / aspect)
        let height = screen.height + 2 * (edge + bezel)
        // An iPhone 17 Pro Max's screen corners, and an iPad Pro's, with the bezel and edge around them.
        let screenRadius = screen.width * (pad ? 0.018 : 0.138), radius = screenRadius + bezel + edge
        let metal = pad
            ? [Color(hex: 0x6E6E73), Color(hex: 0x2C2C2E), Color(hex: 0x1C1C1E), Color(hex: 0x48484A)]
            : [Color(hex: 0x9A9AA0), Color(hex: 0x3A3A3C), Color(hex: 0x1D1D1F), Color(hex: 0x3A3A3C), Color(hex: 0x8E8E93)]
        let shade = Color(red: 0.16, green: 0, blue: 0.02)
        ZStack(alignment: .topLeading) {
            LinearGradient(stops: [.init(color: Color(hex: 0xE5484D), location: 0), .init(color: Color(hex: 0xB4242D), location: 0.55),
                                   .init(color: Color(hex: 0x8E1720), location: 1)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0xFF8C8C).opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.02), startRadius: 0,
                           endRadius: max(size.width * 0.8, size.height * 0.4))
            VStack(spacing: unit * 0.022) {
                Text("\(caption.0) \(Text(caption.1).foregroundStyle(Color(hex: 0xFFE08A)))")
                    .font(.system(size: unit * 0.094, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(pad ? caption.2.replacingOccurrences(of: "\n", with: " ") : caption.2)
                    .font(.system(size: unit * 0.041, weight: .medium))
                    .opacity(0.86)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(width: size.width * 0.86)
            .offset(x: size.width * 0.07, y: size.height * (pad ? 0.055 : 0.058))
            // The buttons stand out of the edge, behind it.
            ForEach(Array(buttons(pad: pad).enumerated()), id: \.offset) { _, button in
                let out = width * (pad ? 0.003 : 0.006) * button.depth
                RoundedRectangle(cornerRadius: out, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x5A5A5E), Color(hex: 0x2A2A2C), Color(hex: 0x5A5A5E)],
                                         startPoint: button.side == .top ? .top : .leading, endPoint: button.side == .top ? .bottom : .trailing))
                    .frame(width: button.side == .top ? width * button.length : out + edge,
                           height: button.side == .top ? out + edge : height * button.length)
                    .offset(x: button.side == .left ? left - out : button.side == .right ? left + width - edge : left + width * button.at,
                            y: button.side == .top ? top - out : top + height * button.at)
            }
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: metal, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width, height: height)
                .shadow(color: shade.opacity(0.35), radius: width * 0.01, y: width * 0.008)
                .shadow(color: shade.opacity(0.45), radius: width * 0.04, y: width * 0.03)
                .offset(x: left, y: top)
            // Light caught along the edge.
            RoundedRectangle(cornerRadius: radius - edge * 0.35, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: max(1, edge * 0.18))
                .frame(width: width - edge * 0.7, height: height - edge * 0.7)
                .offset(x: left + edge * 0.35, y: top + edge * 0.35)
            RoundedRectangle(cornerRadius: radius - edge, style: .continuous)
                .fill(Color(hex: 0x050506))
                .frame(width: width - 2 * edge, height: height - 2 * edge)
                .offset(x: left + edge, y: top + edge)
            Image(nsImage: shot).resizable()
                .frame(width: screen.width, height: screen.height)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
                .offset(x: left + edge + bezel, y: top + edge + bezel)
            if pad {
                // The front camera, on the long edge, which is on the right held upright.
                let camera = width * 0.006
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x2A3550), Color(hex: 0x0A0A0C)], center: UnitPoint(x: 0.35, y: 0.35),
                                         startRadius: 0, endRadius: camera * 0.5))
                    .frame(width: camera, height: camera)
                    .offset(x: left + width - edge - bezel / 2 - camera / 2, y: top + height / 2 - camera / 2)
            } else {
                // The Dynamic Island: 126 by 37 points of a screen 440 points wide, 11 from its top.
                Capsule()
                    .fill(.black)
                    .frame(width: screen.width * 126 / 440, height: screen.width * 37 / 440)
                    .offset(x: (size.width - screen.width * 126 / 440) / 2, y: top + edge + bezel + screen.width * 11 / 440)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }

    /// Where a device's buttons are, along a side, as parts of its length, and how far they stand out.
    private func buttons(pad: Bool) -> [(side: Side, at: CGFloat, length: CGFloat, depth: CGFloat)] {
        pad
            ? [(.top, 0.84, 0.055, 1), (.right, 0.035, 0.04, 1), (.right, 0.085, 0.04, 1)]
            : [(.left, 0.175, 0.04, 1), (.left, 0.245, 0.068, 1), (.left, 0.33, 0.068, 1), (.right, 0.27, 0.105, 1), (.right, 0.55, 0.06, 0.6)]
    }

    private enum Side { case left, right, top }
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
        let renderer = ImageRenderer(content: Listing(shot: image, size: size, caption: caption))
        renderer.scale = 1
        renderer.isOpaque = true   // App Store Connect refuses transparency
        try! NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
            .write(to: listing.appendingPathComponent(file.lastPathComponent))
    }
}
