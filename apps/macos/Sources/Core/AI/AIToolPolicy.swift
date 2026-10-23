import Foundation

/// Checks a value against the part of JSON Schema that tool arguments need: type, required, properties, enum, ranges, lengths,
/// patterns, items and `additionalProperties: false`. It reports problems in words; an empty list means the value fits.
enum JSONSchemaValidator {
    static let maxDepth = 8

    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "arguments", depth: Int = 0) -> [String] {
        guard depth <= maxDepth else { return ["\(path) is nested too deeply"] }
        var problems: [String] = []
        if let type = schema["type"]?.stringValue, !matches(value, type: type) {
            return ["\(path) must be \(type)"]
        }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) { problems.append("\(path) is not one of the allowed values") }
        switch value {
        case .string(let s):
            if let min = schema["minLength"]?.numberValue, Double(s.count) < min { problems.append("\(path) is too short") }
            if let max = schema["maxLength"]?.numberValue, Double(s.count) > max { problems.append("\(path) is too long") }
            if let pattern = schema["pattern"]?.stringValue, let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil { problems.append("\(path) is not in the expected form") }
        case .number(let n):
            if let min = schema["minimum"]?.numberValue, n < min { problems.append("\(path) is below \(min)") }
            if let max = schema["maximum"]?.numberValue, n > max { problems.append("\(path) is above \(max)") }
        case .array(let items):
            if let max = schema["maxItems"]?.numberValue, Double(items.count) > max { problems.append("\(path) has too many items") }
            if let itemSchema = schema["items"] {
                for (i, item) in items.enumerated() { problems += validate(item, against: itemSchema, path: "\(path)[\(i)]", depth: depth + 1) }
            }
        case .object(let object):
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[name] == nil { problems.append("\(path).\(name) is required") }
            let properties = schema["properties"]?.objectValue ?? [:]
            for (name, inner) in object {
                if let propertySchema = properties[name] { problems += validate(inner, against: propertySchema, path: "\(path).\(name)", depth: depth + 1) }
                else if case .bool(false)? = schema["additionalProperties"] { problems.append("\(path).\(name) is not a known argument") }
            }
        default: break
        }
        return problems
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object), ("null", .null), ("number", .number): return true
        case ("integer", .number(let n)): return n == n.rounded()
        default: return false
        }
    }
}

enum AIApprovalSetting: String, Codable, CaseIterable {
    case ask, always, never
    var title: String { self == .ask ? "Ask each time" : (self == .always ? "Allow" : "Never") }
}

enum AIToolDecision: Equatable {
    case allow
    case confirm(reason: String)
    case deny(reason: String)
}

struct AIToolSettings: Codable, Equatable {
    /// By tool name. A tool not listed asks.
    var perTool: [String: AIApprovalSetting] = [:]
    /// Tools the model may use at all, by feature. A feature not listed may use none.
    var toolsByFeature: [String: [String]] = [:]
}

struct AIToolContext {
    var feature: AIFeature
    var localOnlyMode: Bool
    /// The content in this conversation carried wording that looks like orders to the model.
    var suspectedInjection: Bool
    /// The call came from outside Kriya (an MCP client), not from one of Kriya's own features.
    var fromExternalClient = false
}

enum AIToolPolicy {
    static let maxArgumentBytes = 20_000
    static let namePattern = #"^[A-Za-z][A-Za-z0-9_.\-]{0,63}$"#

    enum Problem: Error, Equatable, LocalizedError {
        case unknownTool(String)
        case badName
        case badArguments([String])
        case tooLarge
        var errorDescription: String? {
            switch self {
            case .unknownTool(let n): return "The model asked for a tool Kriya does not have: \(n)."
            case .badName: return "The model asked for a tool with an invalid name."
            case .badArguments(let list): return "The arguments were not valid: \(list.prefix(3).joined(separator: "; "))."
            case .tooLarge: return "The arguments were too large."
            }
        }
    }

    /// The first two steps: the name must be one of the registered tools, and the arguments must fit that tool's schema.
    static func validate(_ call: AIToolCall, registry: [AITool]) -> Result<AITool, Problem> {
        guard call.name.range(of: namePattern, options: .regularExpression) != nil else { return .failure(.badName) }
        guard let tool = registry.first(where: { $0.name == call.name }) else { return .failure(.unknownTool(call.name)) }
        guard JSONValue.object(call.arguments).text.utf8.count <= maxArgumentBytes else { return .failure(.tooLarge) }
        let problems = JSONSchemaValidator.validate(.object(call.arguments), against: tool.parameters)
        return problems.isEmpty ? .success(tool) : .failure(.badArguments(problems))
    }

    /// Whether to run it, ask first, or refuse. Deleting, moving, running scripts and controlling apps always ask, and the person
    /// cannot turn that off. Anything above reading asks when the conversation held wording that looked like orders.
    static func decide(_ tool: AITool, settings: AIToolSettings, context: AIToolContext) -> AIToolDecision {
        if context.localOnlyMode && tool.risk == .externalNetwork { return .deny(reason: "Local-only mode is on.") }
        if let allowed = settings.toolsByFeature[context.feature.rawValue], !allowed.contains(tool.name), !context.fromExternalClient {
            return .deny(reason: "\(context.feature.title) is not allowed to use this tool.")
        }
        if settings.toolsByFeature[context.feature.rawValue] == nil && !context.fromExternalClient && tool.risk > .readOnly {
            return .deny(reason: "No tools are switched on for \(context.feature.title).")
        }
        let setting = settings.perTool[tool.name] ?? .ask
        if setting == .never { return .deny(reason: "You turned this tool off.") }
        if tool.risk >= .destructive { return .confirm(reason: "\(tool.risk.title). Kriya always asks before this.") }
        if context.suspectedInjection && tool.risk > .readOnly { return .confirm(reason: "The content the AI read contained wording that looks like instructions. Check this is what you want.") }
        if context.fromExternalClient && tool.risk >= .sensitiveRead { return .confirm(reason: "An outside program is asking for \(tool.risk.title.lowercased()).") }
        if tool.risk == .readOnly { return .allow }
        return setting == .always ? .allow : .confirm(reason: tool.risk.title + ".")
    }
}
