import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1), NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!.draw(in: tile, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(red: 0.43, green: 0.61, blue: 1, alpha: 1)]))
    let symbol = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let r = NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
    symbol.draw(in: r)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
