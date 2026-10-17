// Draws Folio's icon: a page with a folded corner, and a highlighter stroke across it.
// `swift icon/icon.swift` writes icon/Folio.icns and icon/logo.png.
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) { self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
}

/// The page, its top right corner folded away.
struct PageShape: Shape {
    let fold, radius: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: radius)
        p.closeSubpath()
        return p
    }
}

/// The folded corner, lying on the page: a triangle with its right angle at the bottom left.
struct FlapShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: r.width * 0.16)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A highlighter's stroke, its ends cut at the slant of a chisel tip.
struct StrokeShape: Shape {
    func path(in r: CGRect) -> Path {
        let slant = r.height * 0.4
        var p = Path()
        p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// 1024 points square, on Apple's grid: an 824-point squircle with its shadow.
struct Icon: View {
    let page = CGSize(width: 480, height: 600), fold: CGFloat = 132

    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(hex: 0xE5484D), Color(hex: 0x9E1B25)], startPoint: .top, endPoint: .bottom)
            ZStack(alignment: .topLeading) {
                PageShape(fold: fold, radius: 30).fill(.white)
                    .shadow(color: .black.opacity(0.32), radius: 30, y: 18)
                // Lines of text, the third highlighted.
                VStack(alignment: .leading, spacing: 38) {
                    ForEach(Array([250, 360, 330, 360, 290, 200].enumerated()), id: \.offset) { line, width in
                        Capsule().fill(Color(hex: 0xD5D7DD)).frame(width: CGFloat(width), height: 24)
                            .overlay(alignment: .leading) {
                                if line == 2 {
                                    StrokeShape().fill(Color(hex: 0xFFD60A)).blendMode(.multiply).frame(width: 400, height: 76).offset(x: -18)
                                }
                            }
                    }
                }
                .padding(.leading, 60)
                .padding(.top, 176)
                FlapShape()
                    .fill(LinearGradient(colors: [Color(hex: 0xC9CCD3), Color(hex: 0xF4F5F7)], startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(width: fold, height: fold)
                    .shadow(color: .black.opacity(0.22), radius: 10, x: -6, y: 8)
                    .offset(x: page.width - fold)
            }
            .frame(width: page.width, height: page.height)
        }
        .frame(width: 824, height: 824)
        .clipShape(squircle)
        .overlay(squircle.strokeBorder(.white.opacity(0.18), lineWidth: 3))
        // Flattened first, or the shadow falls under every line of text too.
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 12, y: 10)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func png(_ pixels: Int) -> Data {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = CGFloat(pixels) / 1024
    return NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
}

MainActor.assumeIsolated {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let set = FileManager.default.temporaryDirectory.appendingPathComponent("Folio.iconset")
    try? FileManager.default.removeItem(at: set)
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try! png(size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
        try! png(size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    try! png(1024).write(to: folder.appendingPathComponent("logo.png"))
    let iconutil = try! Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", set.path, "-o", folder.appendingPathComponent("Folio.icns").path])
    iconutil.waitUntilExit()
}
