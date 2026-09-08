#!/usr/bin/env swift
//
// Regenerate Illogical's macOS app icon set from one square master image.
//
//   ./scripts/make-appicon.swift images/illogical.png \
//       clients/macos/Illogical/Supporting/Assets.xcassets/AppIcon.appiconset
//
// This exists because the ten PNGs it writes are not the artwork. They are the
// artwork put on Apple's grid, and the grid is the part a human cannot eyeball
// back out of a committed binary: a macOS icon that ignores it sits visibly
// larger than its neighbours in the Dock, and one that guesses at the corner
// sits visibly *rounder*. Both are the kind of wrong you only see next to
// Finder. So the numbers live here, named, and the PNGs are output.
//
//
// ## The grid
//
// On a 1024pt canvas the artwork is an 824x824 rounded square, centred. The
// remaining 100pt on each side is not padding to taste -- it is the margin
// every system icon leaves, and it is where the shadow goes. An icon drawn
// edge to edge looks oversized beside anything Apple ships.
//
// The corner is 185.4pt (22.5% of 824) and *continuous*, not circular. That
// distinction is the whole reason SwiftUI is imported into a build script:
// `RoundedRectangle(style: .continuous)` is the only place the exact curve
// Apple uses is available as a path. A plain `CGPath(roundedRect:)` at the
// same radius is close, and close is what makes an icon look off-brand at 512
// without anyone being able to say why.
//
//
// ## Why every size is rendered rather than scaled
//
// The set carries 16pt through 512pt at 1x and 2x. Each is drawn from the
// master at 4x its final pixel size and then downsampled once, so the corner
// and the glyph are antialiased by supersampling rather than by whatever a
// path fill produces on a 16-pixel canvas. Rendering the 1024 and scaling *it*
// down to 16 is a pixel cheaper and visibly muddier, because the shadow and
// the margin scale with it into a grey smear.
//
// Alpha is premultiplied and the space is sRGB: `actool` re-encodes these
// anyway, but a mismatched profile survives that step and shifts the gradient.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Apple's macOS icon grid, in points on a 1024 canvas.
let canvas: CGFloat = 1024
let bodySide: CGFloat = 824
let cornerRadius: CGFloat = 185.4

// The shadow under the body. Well inside the 100pt margin, so no size in the
// set clips it: 10 down plus 20 of blur reaches 30 of the 100 available.
let shadowOffset: CGFloat = 10
let shadowBlur: CGFloat = 20
let shadowAlpha: CGFloat = 0.25

// Draw at 4x, downsample once. See above.
let supersample = 4

// Every slot macOS asks for, as (point size, scale). The filenames follow
// Xcode's own convention so the set reads the same as one Xcode wrote.
let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        "usage: make-appicon.swift <master.png> <AppIcon.appiconset>\n".data(using: .utf8)!)
    exit(2)
}
let masterURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(masterURL as CFURL, nil),
    let master = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    FileHandle.standardError.write("cannot read \(masterURL.path)\n".data(using: .utf8)!)
    exit(1)
}
guard master.width == master.height else {
    FileHandle.standardError.write(
        "master must be square, got \(master.width)x\(master.height)\n".data(using: .utf8)!)
    exit(1)
}

/// A square bitmap context, sRGB and premultiplied.
func context(side: Int) -> CGContext {
    guard
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("cannot allocate a \(side)x\(side) context") }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// The master, masked to the grid's rounded square and shadowed, at `pixels`.
func icon(pixels: Int) -> CGImage {
    let side = pixels * supersample
    let scale = CGFloat(side) / canvas
    let ctx = context(side: side)

    let body = CGRect(
        x: (canvas - bodySide) / 2 * scale, y: (canvas - bodySide) / 2 * scale,
        width: bodySide * scale, height: bodySide * scale)
    let shape = RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous)
        .path(in: body).cgPath

    // The shadow, cast by filling the shape opaquely underneath. Negative height
    // is downward: this context's origin is bottom left.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -shadowOffset * scale), blur: shadowBlur * scale,
        color: CGColor(gray: 0, alpha: shadowAlpha))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(master, in: body)
    ctx.restoreGState()

    guard let supersampled = ctx.makeImage() else { fatalError("render failed at \(pixels)px") }
    guard pixels != side else { return supersampled }

    let down = context(side: pixels)
    down.draw(supersampled, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let result = down.makeImage() else { fatalError("downsample failed at \(pixels)px") }
    return result
}

func writePNG(_ image: CGImage, to url: URL) {
    guard
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

var entries: [String] = []
for slot in slots {
    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let filename = "icon_\(slot.points)x\(slot.points)\(suffix).png"
    let pixels = slot.points * slot.scale
    writePNG(icon(pixels: pixels), to: outputURL.appendingPathComponent(filename))
    entries.append(
        """
            {
              "filename" : "\(filename)",
              "idiom" : "mac",
              "scale" : "\(slot.scale)x",
              "size" : "\(slot.points)x\(slot.points)"
            }
        """)
    print("  \(filename)  \(pixels)x\(pixels)")
}

let contents = """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
try contents.write(
    to: outputURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
