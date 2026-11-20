// Generates Resources/AppIcon.icns from the 1024pt-class source artwork.
// The source is a rounded-square icon on an opaque white field. This tool
// clears the surrounding white to transparency, crops to the artwork and
// places it on the standard macOS 1024x1024 icon grid.
//
// Usage: swift Scripts/make-icon.swift [source.png] [output.icns]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : root.appendingPathComponent("Resources/AppIcon-source.png").path)
let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : root.appendingPathComponent("Resources/AppIcon.icns").path)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func makeContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("Could not create a bitmap context.") }
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("Could not create \(url.path).")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("Could not write \(url.path).") }
}

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("Could not read \(sourceURL.path).")
}
let width = source.width, height = source.height
let context = makeContext(width: width, height: height)
context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
guard var pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
    fail("Could not access the source pixels.")
}

// Flood-fill the opaque white border to transparent. Interior highlights are
// enclosed by artwork, so they are preserved.
var cleared = [Bool](repeating: false, count: width * height)
var stack: [Int] = []
func isWhite(_ index: Int) -> Bool {
    let offset = index * 4
    return pixels[offset] >= 246 && pixels[offset + 1] >= 246 && pixels[offset + 2] >= 246
}
for x in 0..<width {
    for y in [0, height - 1] {
        let index = y * width + x
        if !cleared[index], isWhite(index) { cleared[index] = true; stack.append(index) }
    }
}
for y in 0..<height {
    for x in [0, width - 1] {
        let index = y * width + x
        if !cleared[index], isWhite(index) { cleared[index] = true; stack.append(index) }
    }
}
while let index = stack.popLast() {
    let offset = index * 4
    pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0; pixels[offset + 3] = 0
    let x = index % width, y = index / width
    if x > 0 { let next = index - 1; if !cleared[next], isWhite(next) { cleared[next] = true; stack.append(next) } }
    if x + 1 < width { let next = index + 1; if !cleared[next], isWhite(next) { cleared[next] = true; stack.append(next) } }
    if y > 0 { let next = index - width; if !cleared[next], isWhite(next) { cleared[next] = true; stack.append(next) } }
    if y + 1 < height { let next = index + width; if !cleared[next], isWhite(next) { cleared[next] = true; stack.append(next) } }
}

// Crop to the visible artwork.
var minX = width, minY = height, maxX = -1, maxY = -1
for y in 0..<height {
    for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
guard maxX > minX, maxY > minY, let cut = context.makeImage()?.cropping(to: CGRect(
    x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
)) else { fail("The source artwork could not be isolated.") }

// Place the artwork on Apple's 1024x1024 grid: 824pt square with 100pt margins.
let canvas = 1024, artwork = 824, margin = (canvas - artwork) / 2
let master = makeContext(width: canvas, height: canvas)
master.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                 color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
master.draw(cut, in: CGRect(x: margin, y: margin, width: artwork, height: artwork))
guard let masterImage = master.makeImage() else { fail("Could not render the master icon.") }
writePNG(masterImage, to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in variants {
    let scaled = makeContext(width: size, height: size)
    scaled.draw(masterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = scaled.makeImage() else { fail("Could not render \(name).") }
    writePNG(image, to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed.") }
print("Wrote \(outputURL.path)")
