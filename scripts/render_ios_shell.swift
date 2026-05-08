#!/usr/bin/env swift
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ShellRenderer {
    let sideInsetRatio: CGFloat = 0.085
    let topInsetRatio: CGFloat = 0.105
    let bottomInsetRatio: CGFloat = 0.125
    let minInset: CGFloat = 52

    func render(input: URL, output: URL) throws {
        guard let sourceImage = NSImage(contentsOf: input),
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw NSError(domain: "ShellRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to decode image: \(input.path)"])
        }

        let contentWidth = CGFloat(cgImage.width)
        let contentHeight = CGFloat(cgImage.height)

        let sideInset = max(minInset, round(contentWidth * sideInsetRatio))
        let topInset = max(minInset, round(contentWidth * topInsetRatio))
        let bottomInset = max(minInset + 12, round(contentWidth * bottomInsetRatio))

        let outputWidth = Int(contentWidth + sideInset * 2)
        let outputHeight = Int(contentHeight + topInset + bottomInset)

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "ShellRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap context"])
        }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        let outerRect = CGRect(x: 0, y: 0, width: CGFloat(outputWidth), height: CGFloat(outputHeight))
        let shellRadius = min(outerRect.width, outerRect.height) * 0.11
        let shellPath = CGPath(
            roundedRect: outerRect.insetBy(dx: 1.5, dy: 1.5),
            cornerWidth: shellRadius,
            cornerHeight: shellRadius,
            transform: nil
        )

        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.06, alpha: 1.0).cgColor)
        context.addPath(shellPath)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)

        let screenRect = CGRect(
            x: sideInset,
            y: bottomInset,
            width: contentWidth,
            height: contentHeight
        )
        let screenRadius = min(contentWidth, contentHeight) * 0.06
        let screenPath = CGPath(
            roundedRect: screenRect,
            cornerWidth: screenRadius,
            cornerHeight: screenRadius,
            transform: nil
        )

        context.saveGState()
        context.addPath(screenPath)
        context.clip()
        context.draw(cgImage, in: screenRect)
        context.restoreGState()

        context.setStrokeColor(NSColor(calibratedWhite: 0.16, alpha: 1.0).cgColor)
        context.setLineWidth(2)
        context.addPath(screenPath)
        context.strokePath()

        let pillWidth = contentWidth * 0.34
        let pillHeight = max(18, contentWidth * 0.03)
        let pillX = screenRect.midX - pillWidth / 2
        let pillY = screenRect.maxY - pillHeight - contentWidth * 0.028
        let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
        let pillPath = CGPath(
            roundedRect: pillRect,
            cornerWidth: pillHeight / 2,
            cornerHeight: pillHeight / 2,
            transform: nil
        )
        context.setFillColor(NSColor(calibratedWhite: 0.02, alpha: 0.95).cgColor)
        context.addPath(pillPath)
        context.fillPath()

        let earpieceWidth = pillWidth * 0.28
        let earpieceHeight = max(4, pillHeight * 0.18)
        let earpieceRect = CGRect(
            x: pillRect.midX - earpieceWidth / 2,
            y: pillRect.midY - earpieceHeight / 2,
            width: earpieceWidth,
            height: earpieceHeight
        )
        let earpiecePath = CGPath(
            roundedRect: earpieceRect,
            cornerWidth: earpieceHeight / 2,
            cornerHeight: earpieceHeight / 2,
            transform: nil
        )
        context.setFillColor(NSColor(calibratedWhite: 0.28, alpha: 0.9).cgColor)
        context.addPath(earpiecePath)
        context.fillPath()

        let homeWidth = contentWidth * 0.33
        let homeHeight = max(9, contentWidth * 0.011)
        let homeRect = CGRect(
            x: screenRect.midX - homeWidth / 2,
            y: bottomInset * 0.43,
            width: homeWidth,
            height: homeHeight
        )
        let homePath = CGPath(
            roundedRect: homeRect,
            cornerWidth: homeHeight / 2,
            cornerHeight: homeHeight / 2,
            transform: nil
        )
        context.setFillColor(NSColor(calibratedWhite: 0.86, alpha: 0.7).cgColor)
        context.addPath(homePath)
        context.fillPath()

        guard let framedImage = context.makeImage() else {
            throw NSError(domain: "ShellRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to produce output image"])
        }

        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ShellRenderer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to open output destination"])
        }
        CGImageDestinationAddImage(destination, framedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ShellRenderer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unable to write output file"])
        }
    }
}

func usage() {
    fputs("Usage: render_ios_shell.swift <input_root> <output_root>\n", stderr)
}

guard CommandLine.arguments.count == 3 else {
    usage()
    exit(2)
}

let inputRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let fm = FileManager.default

let files = (try? fm.subpathsOfDirectory(atPath: inputRoot.path)) ?? []
let pngs = files.filter { $0.lowercased().hasSuffix(".png") }
if pngs.isEmpty {
    fputs("No PNG files found under \(inputRoot.path)\n", stderr)
    exit(1)
}

let renderer = ShellRenderer()
var rendered = 0
for relative in pngs {
    let inFile = inputRoot.appendingPathComponent(relative)
    let outFile = outputRoot.appendingPathComponent(relative)
    do {
        try renderer.render(input: inFile, output: outFile)
        rendered += 1
    } catch {
        fputs("Failed: \(relative) => \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

print("Rendered \(rendered) files to \(outputRoot.path)")
