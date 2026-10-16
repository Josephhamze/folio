import SwiftUI

/// The signature pad: draw it or type it, then save it for the sign tool.
struct SignatureSheet: View {
    let viewer: Viewer
    @Environment(\.dismiss) private var dismiss
    @State private var typing = false
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false
    @State private var name = ""
    private let pad = CGSize(width: 480, height: 160)

    var body: some View {
        VStack(spacing: 16) {
            Picker("Signature", selection: $typing) {
                Text("Draw").tag(false)
                Text("Type").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Group {
                if typing {
                    VStack {
                        TextField("Your name", text: $name)
                        Text(name).font(.custom("SnellRoundhand", size: 48)).frame(maxHeight: .infinity)
                    }
                } else {
                    SwiftUI.Canvas { context, _ in
                        for stroke in strokes {
                            var path = Path()
                            path.addLines(stroke)
                            context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .background(.white)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !drawing { strokes.append([]) }
                            drawing = true
                            strokes[strokes.count - 1].append(value.location)
                        }
                        .onEnded { _ in drawing = false })
                }
            }
            .frame(width: pad.width, height: pad.height)
            HStack {
                if !typing { Button("Clear") { strokes = [] }.disabled(strokes.isEmpty) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    // The pad's y runs down; a page's runs up.
                    Signature.saved = typing ? .typed(name) : .drawn(strokes.map { $0.map { CGPoint(x: $0.x, y: pad.height - $0.y) } })
                    viewer.tool = .sign
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(typing ? name.trimmingCharacters(in: .whitespaces).isEmpty : strokes.isEmpty)
            }
        }
        .padding(20)
    }
}
