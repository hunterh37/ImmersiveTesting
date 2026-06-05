// ImmersiveCaptureApp — renders Scene.swift's makeScene() in a macOS window and
// captures it with ScreenCaptureKit.
//
// Usage:
//   swift run ImmersiveCaptureApp [--output /path/to/out.png] [--settle 2.0] [--size 512]
//
// Defaults:
//   --output  /tmp/ImmersiveTesting/renders/capture.png
//   --settle  2.0  seconds to wait for Metal/RealityKit to fully render
//   --size    512  window width and height in points

import AppKit
import SwiftUI
import RealityKit
import ScreenCaptureKit

// MARK: - CLI args

struct Config {
    var outputPath: String = {
        let dir = "/tmp/ImmersiveTesting/renders"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/capture.png"
    }()
    var settleSeconds: Double = 2.0
    var size: CGFloat = 512
}

func parseArgs() -> Config {
    var config = Config()
    let args = CommandLine.arguments.dropFirst()
    var iter = args.makeIterator()
    while let arg = iter.next() {
        switch arg {
        case "--output": if let v = iter.next() { config.outputPath = v }
        case "--settle": if let v = iter.next(), let d = Double(v) { config.settleSeconds = d }
        case "--size":   if let v = iter.next(), let d = Double(v) { config.size = CGFloat(d) }
        default: break
        }
    }
    return config
}

// MARK: - App delegate

@MainActor
final class CaptureDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    var window: NSWindow?

    init(config: Config) { self.config = config }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = config.size
        let rect = CGRect(x: 200, y: 200, width: size, height: size)

        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "ImmersiveCaptureApp"
        win.isReleasedWhenClosed = false

        let scene = makeScene()
            .frame(width: size, height: size)
            .ignoresSafeArea()

        win.contentView = NSHostingView(rootView: scene)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        Task { @MainActor in
            await self.captureAfterSettle()
        }
    }

    func captureAfterSettle() async {
        // Let RealityKit drive Metal frames until the scene is fully rendered.
        try? await Task.sleep(for: .seconds(config.settleSeconds))

        guard let win = window else {
            fputs("error: window was nil\n", stderr)
            NSApp.terminate(nil)
            return
        }

        let windowID = CGWindowID(win.windowNumber)

        do {
            let image = try await captureWindow(windowID: windowID, size: config.size)
            try savePNG(image, to: config.outputPath)
            print(config.outputPath)
        } catch {
            fputs("error: \(error)\n", stderr)
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Capture

func captureWindow(windowID: CGWindowID, size: CGFloat) async throws -> CGImage {
    // ScreenCaptureKit captures Metal content for our own window without Screen Recording
    // permission — the permission is only required to capture *other* apps' content.
    let available = try await SCShareableContent.current
    guard let scWin = available.windows.first(where: { $0.windowID == windowID }) else {
        throw CaptureError.windowNotFound
    }

    let filter = SCContentFilter(desktopIndependentWindow: scWin)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(size)
    cfg.height = Int(size)
    cfg.scalesToFit = true
    cfg.showsCursor = false

    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}

func savePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CaptureError.encodingFailed
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw CaptureError.encodingFailed
    }
}

enum CaptureError: Error {
    case windowNotFound
    case encodingFailed
}

// MARK: - Entry point

let config = parseArgs()
let app = NSApplication.shared
let delegate = CaptureDelegate(config: config)
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
