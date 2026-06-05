# Render Capture — Visual Testing for RealityKit Scenes

`ImmersiveCaptureApp` is a macOS helper that renders any `RealityView` scene on a real Metal
surface and captures the result as a PNG. Coding agents use it to see what a RealityKit scene
actually looks like — without a headset, without an iOS Simulator, and without any screen
recording permission.

---

## Quick start

**1. Define the scene** — edit `Sources/ImmersiveCaptureApp/Scene.swift`:

```swift
@MainActor
func makeScene() -> some View {
    RealityView { content in
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.15),
            materials: [SimpleMaterial(color: .systemPurple, isMetallic: true)]
        )
        sphere.position = [0, 0, -0.5]
        content.add(sphere)
    }
}
```

**2. Run the capture** from the package root:

```bash
swift run ImmersiveCaptureApp
```

**3. Read the PNG** — the path is printed to stdout:

```
/tmp/ImmersiveTesting/renders/capture.png
```

Claude Code's `Read` tool renders PNG images inline, so the agent can inspect the scene
immediately.

---

## CLI options

| Flag | Default | Description |
|------|---------|-------------|
| `--output <path>` | `/tmp/ImmersiveTesting/renders/capture.png` | Where to save the PNG |
| `--settle <seconds>` | `2.0` | How long to wait for RealityKit/Metal to fully render before capturing |
| `--size <points>` | `512` | Window width and height |

Examples:

```bash
# Custom output path
swift run ImmersiveCaptureApp --output /tmp/my-scene.png

# Complex scene that needs more time to load assets
swift run ImmersiveCaptureApp --settle 4.0

# Larger viewport
swift run ImmersiveCaptureApp --size 1024 --settle 3.0
```

---

## How it works

1. A macOS `NSWindow` is created and shown on screen with your `RealityView` content.
2. The process waits `--settle` seconds — this lets RealityKit boot its Metal renderer,
   load mesh/material assets, and drive a few frames.
3. `SCScreenshotManager.captureImage` (ScreenCaptureKit) captures the window including its
   Metal framebuffer. No Screen Recording permission is required because the capture target
   is the app's own window.
4. The PNG is written to `--output`, the path is printed to stdout, and the app exits.

Total runtime is roughly `--settle` + ~0.5 s overhead.

---

## Agent workflow

The typical agent loop for iterating on a scene:

```
1. Edit Sources/ImmersiveCaptureApp/Scene.swift
2. swift run ImmersiveCaptureApp
3. Read the PNG at the printed path
4. Adjust the scene → repeat
```

Because `swift run` rebuilds only changed files, incremental iterations are fast (usually
under 3 s compile + settle time).

### Example agent session

```bash
# Run and capture
swift run ImmersiveCaptureApp --settle 2.5 2>/dev/null
# → /tmp/ImmersiveTesting/renders/capture.png

# Read the image (Claude Code renders it inline)
# ... agent observes the rendered scene ...

# Tweak Scene.swift, run again
swift run ImmersiveCaptureApp --settle 2.5 2>/dev/null
```

---

## Scene.swift reference

`Scene.swift` exports exactly one function that `main.swift` calls:

```swift
@MainActor
func makeScene() -> some View
```

The return type must be `some View`. A plain `RealityView` is typical, but any SwiftUI view
hierarchy works — you can layer overlays, add `.background`, use `ZStack`, etc.

The view is hosted in a `512 × 512` window by default (overridable with `--size`). The
background is whatever the `RealityView`'s default background is; wrap in `.background(Color(white: 0.12))` for the standard dark look.

```swift
@MainActor
func makeScene() -> some View {
    RealityView { content in
        // ... build your entity graph
    }
    .background(Color(white: 0.12))
}
```

---

## MCP server (optional)

`ImmersiveTestingMCP` is a stdio JSON-RPC server that exposes rendered PNGs to agents that
communicate over MCP rather than running shell commands directly. It reads from the same
`/tmp/ImmersiveTesting/renders/` directory.

Start it once:

```bash
swift run ImmersiveTestingMCP
```

Add to `.mcp.json`:

```json
{
  "mcpServers": {
    "immersive-testing": {
      "command": "swift",
      "args": ["run", "--package-path", "/absolute/path/to/ImmersiveTesting", "ImmersiveTestingMCP"]
    }
  }
}
```

Available tools:

| Tool | Description |
|------|-------------|
| `immersive_testing_list_renders` | List all PNGs in the renders directory |
| `immersive_testing_get_render` | Return a named PNG as a base64 image |
| `immersive_testing_renders_path` | Return the renders directory path |

Typical flow: run `ImmersiveCaptureApp --output /tmp/ImmersiveTesting/renders/my-scene.png`,
then call `immersive_testing_get_render` with `name: "my-scene"`.

---

## Troubleshooting

**Scene is blank / black**
Increase `--settle`. Complex scenes with many entities, PBR materials, or runtime-loaded
assets may need 3–5 seconds before the first meaningful frame.

**Window appears but nothing renders**
Make sure the package compiles without errors (`swift build --target ImmersiveCaptureApp`).
Also check that `makeScene()` actually adds entities to `content` — a `RealityView` with
an empty closure shows a black viewport.

**`swift run` is slow on first run**
The first build compiles RealityKit, SwiftUI, and ScreenCaptureKit linkages. Subsequent
incremental builds are fast.

**`SCShareableContent` returns no windows**
This can happen if the window is created but not yet visible when the capture fires. The
settle timer covers this for normal scenes; if you hit it, increase `--settle`.
