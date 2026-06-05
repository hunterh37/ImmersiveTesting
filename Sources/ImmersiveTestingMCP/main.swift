// ImmersiveTestingMCP — stdio MCP server that exposes RealityView render snapshots to coding agents.
//
// Start it:
//   swift run --package-path /path/to/ImmersiveTesting ImmersiveTestingMCP
//
// Add to your project's .mcp.json:
//   {
//     "mcpServers": {
//       "immersive-testing": {
//         "command": "swift",
//         "args": ["run", "--package-path", "/absolute/path/to/ImmersiveTesting", "ImmersiveTestingMCP"]
//       }
//     }
//   }
//
// Workflow:
//   1. In your iOS test target, call RenderHarness.captureRender(name: "my-scene") { RealityView {...} }
//   2. Run the test on iOS Simulator (xcodebuild test or Xcode)
//   3. The PNG lands in the shared TMPDIR
//   4. Call the MCP tool `immersive_testing_get_render` with name "my-scene" to see it

import Foundation

// MARK: - MCP protocol types

struct MCPRequest: Decodable {
    let jsonrpc: String
    let id: JSONValue?
    let method: String
    let params: JSONObject?
}

struct MCPNotification: Decodable {
    let jsonrpc: String
    let method: String
}

enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }
}

typealias JSONObject = [String: AnyCodable]

// A type-erased Codable value for arbitrary JSON.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [Any]: try c.encode(v.map { AnyCodable($0) })
        case let v as [String: Any]: try c.encode(v.mapValues { AnyCodable($0) })
        default: try c.encodeNil()
        }
    }
}

// MARK: - Render directory (mirrors RenderHarness.rendersDirectory)

let rendersDirectory: URL = {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImmersiveTesting/renders", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

func listRenders() -> [String] {
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

func getRender(name: String) throws -> String {
    let url = rendersDirectory.appendingPathComponent("\(name).png")
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw MCPError(code: -32602, message: "Render '\(name)' not found at \(url.path)")
    }
    let data = try Data(contentsOf: url)
    return data.base64EncodedString()
}

// MARK: - Response helpers

struct MCPError: Error {
    let code: Int
    let message: String
}

func response(id: JSONValue?, result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id.map(encode) as Any, "result": result]
}

func errorResponse(id: JSONValue?, code: Int, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id.map(encode) as Any, "error": ["code": code, "message": message]]
}

func encode(_ id: JSONValue) -> Any {
    switch id {
    case .string(let s): return s
    case .int(let i): return i
    case .null: return NSNull()
    }
}

// MARK: - Tool definitions

nonisolated(unsafe) let toolsList: [[String: Any]] = [
    [
        "name": "immersive_testing_list_renders",
        "description": "Lists all RealityView render snapshots captured by RenderHarness during test runs. Returns names that can be passed to immersive_testing_get_render.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String]
        ] as [String: Any]
    ],
    [
        "name": "immersive_testing_get_render",
        "description": "Returns a RealityView render snapshot as an image. The agent can see what the RealityKit scene looks like and adjust the code accordingly.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Name of the render (file stem, without .png). Use immersive_testing_list_renders to see available names."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["name"]
        ] as [String: Any]
    ],
    [
        "name": "immersive_testing_capture_screen",
        "description": "Triggers xcrun simctl io booted screenshot while a RenderHarness.showForCapture test is holding the view on screen. Call this while the test is paused/waiting. Returns the captured image immediately.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Name matching the one passed to showForCapture (used for the output filename)."
                ] as [String: Any],
                "device": [
                    "type": "string",
                    "description": "Simulator device UDID or 'booted' (default). Use the UDID from the pending request file if available."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["name"]
        ] as [String: Any]
    ],
    [
        "name": "immersive_testing_renders_path",
        "description": "Returns the filesystem path where RenderHarness saves PNG files. Useful for debugging path mismatch issues between the simulator and the MCP server.",
        "inputSchema": [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String]
        ] as [String: Any]
    ]
]

// MARK: - Request handling

func handle(request: MCPRequest) -> [String: Any] {
    let id = request.id
    switch request.method {
    case "initialize":
        return response(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "ImmersiveTestingMCP", "version": "1.0.0"]
        ])

    case "tools/list":
        return response(id: id, result: ["tools": toolsList])

    case "tools/call":
        guard let params = request.params,
              let toolName = params["name"]?.value as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing tool name")
        }
        let args = params["arguments"]?.value as? [String: Any] ?? [:]
        return handleToolCall(id: id, name: toolName, arguments: args)

    default:
        return errorResponse(id: id, code: -32601, message: "Method not found: \(request.method)")
    }
}

func handleToolCall(id: JSONValue?, name: String, arguments: [String: Any]) -> [String: Any] {
    switch name {
    case "immersive_testing_list_renders":
        let names = listRenders()
        let text = names.isEmpty
            ? "No renders found. Run a test that calls RenderHarness.captureRender() first.\nRenders directory: \(rendersDirectory.path)"
            : "Available renders (\(names.count)):\n" + names.map { "  • \($0)" }.joined(separator: "\n")
        return response(id: id, result: [
            "content": [["type": "text", "text": text]]
        ])

    case "immersive_testing_get_render":
        guard let renderName = arguments["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing required argument: name")
        }
        do {
            let base64 = try getRender(name: renderName)
            return response(id: id, result: [
                "content": [
                    ["type": "image", "data": base64, "mimeType": "image/png"]
                ]
            ])
        } catch let e as MCPError {
            return errorResponse(id: id, code: e.code, message: e.message)
        } catch {
            return errorResponse(id: id, code: -32603, message: error.localizedDescription)
        }

    case "immersive_testing_capture_screen":
        guard let renderName = arguments["name"] as? String else {
            return errorResponse(id: id, code: -32602, message: "Missing required argument: name")
        }
        let device = arguments["device"] as? String ?? "booted"

        // Check for a pending-capture request file written by showForCapture.
        let outputURL = rendersDirectory.appendingPathComponent("\(renderName).png")
        var targetDevice = device
        let requestURL = rendersDirectory.appendingPathComponent(".pending-\(renderName).json")
        if let data = try? Data(contentsOf: requestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let udid = json["deviceUDID"] {
            targetDevice = udid
        }

        // Run xcrun simctl io screenshot from macOS (where it has access to CoreSimulator).
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "io", targetDevice, "screenshot", outputURL.path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return errorResponse(id: id, code: -32603, message: "xcrun failed: \(error)")
        }
        guard task.terminationStatus == 0,
              let pngData = try? Data(contentsOf: outputURL) else {
            return errorResponse(id: id, code: -32603,
                message: "simctl screenshot failed (exit \(task.terminationStatus)). Is the simulator booted and showing the view?")
        }
        let base64 = pngData.base64EncodedString()
        return response(id: id, result: [
            "content": [["type": "image", "data": base64, "mimeType": "image/png"]]
        ])

    case "immersive_testing_renders_path":
        return response(id: id, result: [
            "content": [["type": "text", "text": rendersDirectory.path]]
        ])

    default:
        return errorResponse(id: id, code: -32601, message: "Unknown tool: \(name)")
    }
}

// MARK: - Stdio loop

let encoder = JSONEncoder()
let decoder = JSONDecoder()

func writeResponse(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

// Log to stderr so it doesn't pollute the MCP JSON stream.
func log(_ message: String) {
    fputs("[ImmersiveTestingMCP] \(message)\n", stderr)
}

log("Starting. Reads renders from: \(rendersDirectory.path)")

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let data = line.data(using: .utf8) else { continue }

    // Ignore notifications (no id field or no method we care about).
    if let notif = try? decoder.decode(MCPNotification.self, from: data),
       notif.method == "notifications/initialized" {
        continue
    }

    guard let request = try? decoder.decode(MCPRequest.self, from: data) else {
        log("Failed to decode request: \(line.prefix(200))")
        continue
    }

    let resp = handle(request: request)
    writeResponse(resp)
}
