#if os(iOS)
import UIKit

// The shared code names AppKit's types. On iOS, PDFKit takes UIKit's, which do the same jobs under these names.
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage
typealias NSBezierPath = UIBezierPath
#endif
