import Foundation

/// How to point each AI app at Kriya's MCP server. The formats are the ones those apps document: Claude Code adds a remote server with
/// `claude mcp add --transport http … --header …`; Cursor reads `url` and `headers` from `mcp.json`; Claude Desktop only starts local
/// programs, so it reaches a remote server through the `mcp-remote` bridge (which needs Node.js).
struct MCPClientSetup: Identifiable, Equatable {
    let id: String
    let app: String
    /// Where the text goes, in words.
    let instructions: String
    /// The text to copy.
    let text: String
    /// The secret is inside `text`, so copying it is time-limited.
    let containsSecret = true

    static func all(endpoint: String, secret: String) -> [MCPClientSetup] {
        [
            MCPClientSetup(
                id: "claude-code", app: "Claude Code",
                instructions: "Run this once in Terminal. Add --scope user to make it available in every project.",
                text: "claude mcp add --transport http kriya \(endpoint) --header \"Authorization: Bearer \(secret)\""),
            MCPClientSetup(
                id: "cursor", app: "Cursor",
                instructions: "Put this in ~/.cursor/mcp.json (all projects) or .cursor/mcp.json (one project), then restart Cursor.",
                text: json(["mcpServers": ["kriya": ["url": endpoint, "headers": ["Authorization": "Bearer \(secret)"]]]])),
            MCPClientSetup(
                id: "claude-desktop", app: "Claude Desktop",
                instructions: "Add this to ~/Library/Application Support/Claude/claude_desktop_config.json (Claude Desktop › Settings › Developer › Edit Config), then quit and reopen Claude Desktop. It needs Node.js for npx.",
                text: json(["mcpServers": ["kriya": [
                    "command": "npx",
                    "args": ["-y", "mcp-remote", endpoint, "--header", "Authorization:${KRIYA_AUTH}"],
                    "env": ["KRIYA_AUTH": "Bearer \(secret)"],
                ] as [String: Any]]]) ),
            MCPClientSetup(
                id: "other", app: "Any other app",
                instructions: "For an app that accepts a remote MCP server with a URL and headers.",
                text: json(["mcpServers": ["kriya": ["url": endpoint, "headers": ["Authorization": "Bearer \(secret)"]]]])),
        ]
    }

    /// The same text with the secret hidden, for showing on screen.
    func masked(secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: String(repeating: "•", count: 12))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
