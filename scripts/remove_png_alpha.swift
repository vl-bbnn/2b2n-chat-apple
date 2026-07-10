#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

var temporaryURLsToClean = [URL]()

func fail(_ message: String) -> Never {
    for url in temporaryURLsToClean {
        try? FileManager.default.removeItem(at: url)
    }
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: remove_png_alpha.swift PNG_PATH [PNG_PATH ...]\n".utf8))
    exit(2)
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let rgbaBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.premultipliedLast.rawValue
let rgbBitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
    | CGImageAlphaInfo.noneSkipLast.rawValue

struct PreparedImage {
    let originalURL: URL
    let temporaryURL: URL
}

func renderedPixels(for image: CGImage, bitmapInfo: UInt32, path: String) -> (Data, CGImage) {
    let bytesPerRow = image.width * 4
    var pixels = Data(count: bytesPerRow * image.height)
    let renderedImage: CGImage = pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            fail("failed to create sRGB context: \(path)")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else {
            fail("failed to create rendered image: \(path)")
        }
        return result
    }
    return (pixels, renderedImage)
}

var preparedImages = [PreparedImage]()

for path in CommandLine.arguments.dropFirst() {
    let fileURL = URL(fileURLWithPath: path)
    let temporaryURL = fileURL.deletingLastPathComponent()
        .appendingPathComponent(".\(fileURL.lastPathComponent).no-alpha-\(UUID().uuidString)")
    temporaryURLsToClean.append(temporaryURL)

    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("failed to read image: \(path)")
    }

    let (opaquePixels, _) = renderedPixels(for: image, bitmapInfo: rgbaBitmapInfo, path: path)
    for alphaOffset in stride(from: 3, to: opaquePixels.count, by: 4)
        where opaquePixels[alphaOffset] != 255 {
        fail("refusing to remove non-opaque alpha: \(path)")
    }

    let (_, noAlphaImage) = renderedPixels(for: image, bitmapInfo: rgbBitmapInfo, path: path)
    guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL,
                                                             UTType.png.identifier as CFString,
                                                             1,
                                                             nil) else {
        fail("failed to create output image: \(path)")
    }
    CGImageDestinationAddImage(destination, noAlphaImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        try? FileManager.default.removeItem(at: temporaryURL)
        fail("failed to write output image: \(path)")
    }

    guard let encodedSource = CGImageSourceCreateWithURL(temporaryURL as CFURL, nil),
          let encodedImage = CGImageSourceCreateImageAtIndex(encodedSource, 0, nil) else {
        try? FileManager.default.removeItem(at: temporaryURL)
        fail("failed to verify output image: \(path)")
    }
    guard encodedImage.alphaInfo == .none || encodedImage.alphaInfo == .noneSkipFirst
            || encodedImage.alphaInfo == .noneSkipLast else {
        try? FileManager.default.removeItem(at: temporaryURL)
        fail("encoded output still has alpha: \(path)")
    }

    let (encodedPixels, _) = renderedPixels(for: encodedImage,
                                            bitmapInfo: rgbaBitmapInfo,
                                            path: temporaryURL.path)
    guard opaquePixels.count == encodedPixels.count else {
        try? FileManager.default.removeItem(at: temporaryURL)
        fail("encoded output dimensions changed: \(path)")
    }
    for offset in stride(from: 0, to: opaquePixels.count, by: 4) {
        guard opaquePixels[offset] == encodedPixels[offset],
              opaquePixels[offset + 1] == encodedPixels[offset + 1],
              opaquePixels[offset + 2] == encodedPixels[offset + 2] else {
            try? FileManager.default.removeItem(at: temporaryURL)
            fail("encoded output RGB pixels changed: \(path)")
        }
    }

    preparedImages.append(PreparedImage(originalURL: fileURL, temporaryURL: temporaryURL))
}

for preparedImage in preparedImages {
    do {
        _ = try FileManager.default.replaceItemAt(preparedImage.originalURL,
                                                  withItemAt: preparedImage.temporaryURL)
        temporaryURLsToClean.removeAll { $0 == preparedImage.temporaryURL }
    } catch {
        fail("failed to atomically replace \(preparedImage.originalURL.path): \(error)")
    }
}
