// RenderHarness: captures a PNG of any SwiftUI view containing a RealityView.
//
// Agent workflow — no MCP required:
//   1. Write a test that calls RenderHarness.captureRender(name: "my-scene") { RealityView {...} }
//   2. Run the test (xcodebuild test on iOS Simulator, or swift test on macOS)
//   3. The test prints: "RenderHarness: /private/var/.../ImmersiveTesting/renders/my-scene.png"
//   4. Agent reads that path directly — Claude Code's Read tool handles PNG images natively.
//
// Example test:
//
//   func testMyScene() async throws {
//       let url = try await RenderHarness.captureRender(name: "avatar-idle") {
//           RealityView { content in
//               content.add(makeAvatarEntity())
//           }
//       }
//       add(XCTAttachment(contentsOfFile: url.path))
//   }
//
// Requirements:
//   iOS: runs in an Xcode test target with a host application (xcodebuild test on simulator).
//   macOS: runs in a standard macOS test target (swift test or xcodebuild test).

import SwiftUI
import Foundation

@MainActor
public final class RenderHarness {

    // Renders saved here. The MCP server reads from the same path.
    // On iOS Simulator and macOS, FileManager.default.temporaryDirectory resolves to the same
    // TMPDIR for the same macOS user session, so the MCP server can read what the sim wrote.
    public static var rendersDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmersiveTesting/renders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public struct Options: Sendable {
        /// Render canvas size in points.
        public var size: CGSize
        /// How long to wait before capturing. RealityKit loads assets and drives Metal frames
        /// asynchronously, so complex scenes may need more time.
        public var settleSeconds: Double
        /// Background colour painted behind the RealityView.
        public var backgroundColor: Color
        public init(
            size: CGSize = CGSize(width: 512, height: 512),
            settleSeconds: Double = 1.0,
            backgroundColor: Color = Color(white: 0.12)
        ) {
            self.size = size
            self.settleSeconds = settleSeconds
            self.backgroundColor = backgroundColor
        }
    }

    /// Renders `view` (typically a `RealityView`) off-screen and saves a PNG to
    /// `rendersDirectory/<name>.png`.
    ///
    /// Returns the file URL. Call `add(XCTAttachment(contentsOfFile: url.path))` inside your
    /// test to also embed it in the Xcode test report.
    @discardableResult
    public static func captureRender<V: View>(
        name: String = "snapshot",
        options: Options = Options(),
        @ViewBuilder view: () -> V
    ) async throws -> URL {
        let content = view()
            .frame(width: options.size.width, height: options.size.height)
            .background(options.backgroundColor)

#if os(iOS) || os(visionOS)
        let image = try await captureOniOS(content: content, options: options)
#elseif os(macOS)
        let image = try await captureOnMacOS(content: content, options: options)
#else
        throw RenderError.platformNotSupported
#endif

        guard let pngData = image.pngData() else {
            throw RenderError.encodingFailed
        }

        let outputURL = rendersDirectory.appendingPathComponent("\(name).png")
        try pngData.write(to: outputURL, options: .atomic)
        print("RenderHarness: \(outputURL.path)")
        return outputURL
    }

    /// Shows a view on the simulator's live screen and holds it there so the
    /// ImmersiveTestingMCP server (or the agent directly) can call
    /// `xcrun simctl io booted screenshot` to capture the real Metal framebuffer.
    ///
    /// `xcrun simctl io` must run on the HOST macOS — it cannot be called from inside
    /// the simulator process. Typical agent workflow:
    ///
    ///   1. Run this test in the background (Bash run_in_background: true).
    ///   2. Wait `settleSeconds` for RealityKit to load.
    ///   3. Call the MCP tool `immersive_testing_capture_screen` (or run
    ///      `xcrun simctl io booted screenshot <path>` directly).
    ///   4. Read the PNG.
    ///
    /// The method writes a capture-request JSON to `rendersDirectory/.pending-<name>.json`
    /// immediately after the settle wait so the MCP server knows where to save the file.
    /// It then polls (up to `holdSeconds`) for the PNG to appear before returning.
    #if os(iOS) || os(visionOS)
    @discardableResult
    public static func showForCapture<V: View>(
        name: String = "snapshot",
        options: Options = Options(),
        holdSeconds: Double = 10,
        @ViewBuilder view: () -> V
    ) async throws -> URL {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else {
            throw RenderError.snapshotFailed
        }

        let savedVC = window.rootViewController
        let content = view()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(options.backgroundColor)
            .ignoresSafeArea()

        let vc = UIHostingController(rootView: content)
        window.rootViewController = vc

        // Let RealityKit drive Metal frames and load async resources.
        try await Task.sleep(for: .seconds(options.settleSeconds))

        // Write a capture-request file so the MCP server knows where to save the screenshot.
        let outputURL = rendersDirectory.appendingPathComponent("\(name).png")
        let deviceUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "booted"
        let request: [String: String] = ["name": name, "outputPath": outputURL.path, "deviceUDID": deviceUDID]
        let requestURL = rendersDirectory.appendingPathComponent(".pending-\(name).json")
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            try? data.write(to: requestURL, options: .atomic)
        }

        // Print the exact command the agent can run directly if not using the MCP server.
        print("RenderHarness waiting: xcrun simctl io \(deviceUDID) screenshot '\(outputURL.path)'")
        print("RenderHarness output:  \(outputURL.path)")

        // Poll for the PNG. The MCP server (or agent) should call simctl while we wait.
        let deadline = Date().addingTimeInterval(holdSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: requestURL)
                window.rootViewController = savedVC
                print("RenderHarness: \(outputURL.path)")
                return outputURL
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        try? FileManager.default.removeItem(at: requestURL)
        window.rootViewController = savedVC
        throw RenderError.captureTimeout(name)
    }
    #endif

    /// Lists saved render names (file stems, newest first).
    public static func listRenders() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rendersDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "png" }
            .sorted {
                let aDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let bDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return aDate > bDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
}

// MARK: - Platform capture

#if os(iOS) || os(visionOS)
import UIKit

@MainActor
private func captureOniOS<V: View>(content: V, options: RenderHarness.Options) async throws -> UIImage {
    // CAMetalLayer only allocates drawables for windows in the simulator's visible screen bounds.
    // Off-screen windows get "nextDrawable returning nil" and RealityKit never renders.
    // Solution: temporarily install our view as the root of the already-on-screen key window.
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) else {
        throw RenderError.snapshotFailed
    }

    let savedVC = window.rootViewController

    let vc = UIHostingController(rootView: content)
    window.rootViewController = vc

    // Let RealityKit drive Metal frames and load async resources.
    try await Task.sleep(for: .seconds(options.settleSeconds))

    // snapshotView reads the Metal-composited framebuffer of the live window.
    guard let snapshot = window.snapshotView(afterScreenUpdates: true) else {
        window.rootViewController = savedVC
        throw RenderError.snapshotFailed
    }

    // Restore the original root VC before rendering to bitmap (restore first so RealityKit
    // can clean up its scene gracefully rather than being torn down mid-render).
    window.rootViewController = savedVC

    let captureSize = window.bounds.size
    let renderer = UIGraphicsImageRenderer(size: captureSize)
    return renderer.image { ctx in
        snapshot.layer.render(in: ctx.cgContext)
    }
}
#endif

#if os(macOS)
import AppKit

// On macOS, RealityKit content inside a RealityView renders via Metal. Metal's framebuffer
// isn't accessible through the standard NSView drawing path, so this capture uses
// NSView.cacheDisplay which reads the composited backing store after layout and display
// passes complete. It faithfully captures the rendered result as long as the window has
// gone through at least one display cycle.
@MainActor
private func captureOnMacOS<V: View>(content: V, options: RenderHarness.Options) async throws -> UIImage {
    let size = options.size
    let rect = CGRect(origin: .zero, size: size)

    // Offscreen panel — orderFront so it participates in compositing, but positioned far off screen.
    let window = NSPanel(
        contentRect: rect,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = true
    window.level = .floating

    let vc = NSHostingController(rootView: content)
    vc.view.frame = rect
    window.contentViewController = vc
    window.setFrameOrigin(CGPoint(x: -100_000, y: -100_000))
    window.orderFront(nil)

    // Allow Metal to drive frames and RealityKit to load assets.
    try await Task.sleep(for: .seconds(options.settleSeconds))

    // cacheDisplay reads the composited backing store (including Metal layers).
    guard let bitmapRep = vc.view.bitmapImageRepForCachingDisplay(in: rect) else {
        throw RenderError.snapshotFailed
    }
    vc.view.cacheDisplay(in: rect, to: bitmapRep)
    window.orderOut(nil)

    let nsImage = NSImage(size: size)
    nsImage.addRepresentation(bitmapRep)
    return UIImage(nsImage: nsImage)
}

// Minimal UIImage shim on macOS so callers stay platform-agnostic.
public final class UIImage {
    public let nsImage: NSImage
    public init(nsImage: NSImage) { self.nsImage = nsImage }
    public func pngData() -> Data? {
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif

// MARK: - posix_spawn helper

// system() is Swift-unavailable on iOS targets. posix_spawn is a raw POSIX primitive with
// no such restriction, and works inside iOS Simulator (unsandboxed macOS process).
import Darwin

private func spawnAndWait(executable: String, arguments: [String]) -> Int32 {
    var pid: pid_t = 0
    var cArgs: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
    cArgs.append(nil)
    let spawnResult = cArgs.withUnsafeMutableBufferPointer { ptr -> Int32 in
        posix_spawn(&pid, executable, nil, nil, ptr.baseAddress!, environ)
    }
    cArgs.compactMap { $0 }.forEach { free($0) }
    guard spawnResult == 0 else { return -1 }
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status
}

// MARK: - Errors

public enum RenderError: Error, LocalizedError {
    case snapshotFailed
    case encodingFailed
    case platformNotSupported
    case renderNotFound(String)
    case captureTimeout(String)

    public var errorDescription: String? {
        switch self {
        case .snapshotFailed:
            "Metal snapshot failed — the view may not have rendered yet"
        case .encodingFailed:
            "Failed to encode snapshot as PNG"
        case .platformNotSupported:
            "RenderHarness is not supported on this platform"
        case .renderNotFound(let name):
            "No render named '\(name)' in renders directory"
        case .captureTimeout(let name):
            "Timed out waiting for '\(name).png' — call 'xcrun simctl io booted screenshot <path>' from macOS while the test is waiting"
        }
    }
}
