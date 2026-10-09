// winshot <output.png> [filter]: captures the largest on-screen window owned by Wine (or whose
// owner/title contains `filter`) and reports how much of it isn't black.
// Prints: "<window id> <non-black %> <owner> / <title>", then "dialog: <title>" for each Wine
// window that looks like an error (crash dialogs, assertion boxes, crash reports in Notepad).
// Exit 0 if a window was found, 1 if not.
// Needs the Screen Recording permission for the terminal running it.
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: winshot out.png [filter]"); exit(2) }
let filter = args.count > 2 ? args[2].lowercased() : nil
let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (id: Int, area: Double, label: String)?
var dialogs: [String] = []
let errorWords = ["error", "exception", "assert", "runtime library", "crash", "fatal", "failed", "not responding"]
for w in windows {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let title = w[kCGWindowName as String] as? String ?? ""
    let text = (owner + " " + title).lowercased()
    let isWine = owner.lowercased().contains("wine") || owner.lowercased().hasSuffix(".exe")
    if isWine, errorWords.contains(where: { title.lowercased().contains($0) }) { dialogs.append(title) }
    let matches = filter.map { text.contains($0) } ?? isWine
    guard matches, let bounds = w[kCGWindowBounds as String] as? [String: Double],
          let id = w[kCGWindowNumber as String] as? Int else { continue }
    let area = (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
    if area > 100 * 100, area > (best?.area ?? 0) { best = (id, area, "\(owner) / \(title)") }
}
guard let best else { print("no matching window"); exit(1) }

let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-o", "-l", String(best.id), args[1]]
try capture.run()
capture.waitUntilExit()

// Share of pixels that aren't (near) black, sampled at 64x64.
var nonBlack = 0.0
if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
   let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
   let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 64 * 64 * 4)
    var lit = 0
    for i in 0..<(64 * 64) where Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) > 24 { lit += 1 }
    nonBlack = Double(lit) / Double(64 * 64) * 100
}
print("\(best.id) \(Int(nonBlack)) \(best.label)")
for dialog in dialogs { print("dialog: \(dialog)") }
