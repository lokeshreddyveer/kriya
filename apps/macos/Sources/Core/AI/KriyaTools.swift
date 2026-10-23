import Foundation

/// The tools Kriya offers to a model (its own features, or an outside program through MCP). Each takes named, typed arguments and
/// nothing else: there is no argument that is run as a command, so a model cannot make Kriya execute text it wrote.
enum KriyaTools {
    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)])
    }
    private static func text(_ description: String, max: Int = 200, min: Int = 1, pattern: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description), "minLength": .number(Double(min)), "maxLength": .number(Double(max))]
        if let pattern { o["pattern"] = .string(pattern) }
        return .object(o)
    }
    private static func whole(_ description: String, min: Int, max: Int) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description), "minimum": .number(Double(min)), "maximum": .number(Double(max))])
    }
    /// An absolute path with no control characters.
    private static let pathPattern = #"^/[^\u0000-\u001F]*$"#
    /// The id of something Kriya already has: a workflow, script or command.
    static let idPattern = #"^[A-Za-z0-9_.:@\-]{1,100}$"#

    static let all: [AITool] = [
        AITool(name: "kriya.list_workflows", description: "The user's workflows: each one's id and name, so one can be previewed or run.", parameters: object([:]), risk: .readOnly),
        AITool(name: "kriya.list_scripts", description: "The scripts the user added to the launcher: each one's id and name. The scripts' text is not shown.", parameters: object([:]), risk: .readOnly),
        AITool(name: "kriya.list_commands", description: "Kriya's commands that can have a shortcut: each one's name and title.", parameters: object(["query": text("Part of the title", max: 100, min: 0)]), risk: .readOnly),
        AITool(name: "kriya.search_apps", description: "Find installed apps by name.", parameters: object(["query": text("Part of the app's name", max: 100), "limit": whole("How many to return", min: 1, max: 25)], required: ["query"]), risk: .readOnly),
        AITool(name: "kriya.search_files", description: "Find files by name in the user's folders.", parameters: object(["query": text("Part of the file name", max: 100), "limit": whole("How many to return", min: 1, max: 25)], required: ["query"]), risk: .readOnly),
        AITool(name: "kriya.search_notes", description: "Find notes by words in their title or text.", parameters: object(["query": text("Words to look for", max: 100), "limit": whole("How many to return", min: 1, max: 15)], required: ["query"]), risk: .readOnly),
        AITool(name: "kriya.search_clipboard", description: "Search the clipboard history. Items that look like secrets are never returned.", parameters: object(["query": text("Words to look for", max: 100), "limit": whole("How many to return", min: 1, max: 15)], required: ["query"]), risk: .sensitiveRead),
        AITool(name: "kriya.get_selected_text", description: "The text selected in the front app.", parameters: object([:]), risk: .sensitiveRead),
        AITool(name: "kriya.open_launcher", description: "Open Kriya's launcher, optionally with a search typed in.", parameters: object(["query": text("What to type", max: 100, min: 0)]), risk: .readOnly),
        AITool(name: "kriya.set_audio_profile", description: "Turn a saved sound mode on or off by its name.", parameters: object(["name": text("The mode's name", max: 60)], required: ["name"]), risk: .write),
        AITool(name: "kriya.list_windows", description: "The names of the open windows and their apps.", parameters: object([:]), risk: .readOnly),
        AITool(name: "kriya.preview_workflow", description: "Describe what a saved workflow would do, without running it.", parameters: object(["workflow_id": text("The workflow's id", max: 100, pattern: idPattern)], required: ["workflow_id"]), risk: .readOnly),
        AITool(name: "kriya.get_diagnostics", description: "Kriya's version, the Mac's version and which permissions are on. Names and paths are removed.", parameters: object([:]), risk: .sensitiveRead),
        AITool(name: "kriya.move_file", description: "Move a file or folder inside the user's home folder.", parameters: object(["from": text("Absolute path of the item", max: 1024, pattern: pathPattern), "to": text("Absolute path of the folder to move it into", max: 1024, pattern: pathPattern)], required: ["from", "to"]), risk: .destructive),
        AITool(name: "kriya.delete_file", description: "Move a file or folder to the Trash.", parameters: object(["path": text("Absolute path of the item", max: 1024, pattern: pathPattern)], required: ["path"]), risk: .destructive),
        AITool(name: "kriya.install_app", description: "Install an app with Homebrew, by its cask name.", parameters: object(["cask": text("The cask name", max: 80, pattern: #"^[a-z0-9][a-z0-9@._+\-]{0,79}$"#)], required: ["cask"]), risk: .privileged),
        AITool(name: "kriya.run_script", description: "Run a script the user already added to the launcher, by its id. Text of a script cannot be given.", parameters: object(["script_id": text("The script's id", max: 100, pattern: idPattern)], required: ["script_id"]), risk: .privileged),
        AITool(name: "kriya.execute_workflow", description: "Run a saved workflow by its id. It must already be authorized by the user.", parameters: object(["workflow_id": text("The workflow's id", max: 100, pattern: idPattern)], required: ["workflow_id"]), risk: .privileged),
        AITool(name: "kriya.change_shortcut", description: "Change the key combination of a Kriya command.", parameters: object(["command": text("The command's name", max: 100, pattern: idPattern), "shortcut": text("For example cmd+shift+k", max: 40, pattern: #"^[A-Za-z0-9+ ]{1,40}$"#)], required: ["command", "shortcut"]), risk: .privileged),
        AITool(name: "kriya.export_clipboard", description: "Export the most recent clipboard items, without anything that looks like a secret, to a Markdown file the user chooses in a save panel.", parameters: object(["limit": whole("How many recent items", min: 1, max: 50)], required: ["limit"]), risk: .privileged),
    ]

    static func tool(named name: String) -> AITool? { all.first { $0.name == name } }

    /// Tools that must always be confirmed by the person, whatever else is set.
    static var alwaysConfirmed: [AITool] { all.filter { $0.risk >= .destructive } }
}
