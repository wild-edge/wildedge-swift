import Foundation

enum ToolCallJSONValue: Equatable {
    case object([String: ToolCallJSONValue])
    case array([ToolCallJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    init(any value: Any) throws {
        switch value {
        case let object as [String: Any]:
            var parsed: [String: ToolCallJSONValue] = [:]
            for (key, value) in object {
                parsed[key] = try ToolCallJSONValue(any: value)
            }
            self = .object(parsed)
        case let array as [Any]:
            self = .array(try array.map(ToolCallJSONValue.init(any:)))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(Self.normalizedNumber(number))
            }
        case _ as NSNull:
            self = .null
        default:
            throw NSError(
                domain: "ToolCallJSONValue",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value \(type(of: value))."]
            )
        }
    }

    var canonicalString: String {
        switch self {
        case .object(let object):
            let fields = object.keys.sorted().map { key in
                "\(Self.quoted(key)):\(object[key]?.canonicalString ?? "null")"
            }
            return "{\(fields.joined(separator: ","))}"
        case .array(let array):
            return "[\(array.map(\.canonicalString).joined(separator: ","))]"
        case .string(let string):
            return Self.quoted(string)
        case .number(let number):
            return number
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }

    var foundationObject: Any {
        switch self {
        case .object(let object):
            var result: [String: Any] = [:]
            for (key, value) in object {
                result[key] = value.foundationObject
            }
            return result
        case .array(let array):
            return array.map(\.foundationObject)
        case .string(let string):
            return string
        case .number(let number):
            if let int = Int(number) {
                return int
            }
            return Double(number) ?? number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        }
    }

    private static func normalizedNumber(_ number: NSNumber) -> String {
        let double = number.doubleValue
        guard double.isFinite else { return "\(double)" }
        if double.rounded() == double,
           double >= Double(Int64.min),
           double <= Double(Int64.max) {
            return String(Int64(double))
        }
        return String(format: "%.15g", double)
    }

    private static func quoted(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2
        else {
            return "\"\(string)\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}

struct ToolCallParseResult {
    let value: ToolCallJSONValue?
    let error: String?

    var canonicalJSON: String? {
        value?.canonicalString
    }

    var parsedSuccessfully: Bool {
        value != nil && error == nil
    }
}

enum ToolCallJSON {
    static func parseAndValidate(from text: String) -> ToolCallParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return ToolCallParseResult(value: nil, error: "No JSON output.")
        }
        guard let jsonObjectText = extractFirstJSONObject(from: trimmed) else {
            return ToolCallParseResult(value: nil, error: "No JSON object found.")
        }
        guard let data = jsonObjectText.data(using: .utf8) else {
            return ToolCallParseResult(value: nil, error: "JSON output is not UTF-8.")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let value = try ToolCallJSONValue(any: object)
            try validateToolCall(value)
            return ToolCallParseResult(value: value, error: nil)
        } catch {
            return ToolCallParseResult(value: nil, error: error.localizedDescription)
        }
    }

    static func prettyString(from value: ToolCallJSONValue?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value.foundationObject),
              let data = try? JSONSerialization.data(
                withJSONObject: value.foundationObject,
                options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return value.canonicalString
        }
        return String(data: data, encoding: .utf8)
    }

    private static func extractFirstJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    let endIndex = text.index(after: index)
                    return String(text[startIndex..<endIndex])
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func validateToolCall(_ value: ToolCallJSONValue) throws {
        guard case .object(let object) = value else {
            throw validationError("Tool call must be a JSON object.")
        }
        let expectedTopLevelKeys: Set<String> = ["tool_name", "arguments"]
        guard Set(object.keys) == expectedTopLevelKeys else {
            throw validationError("Tool call must contain only tool_name and arguments.")
        }
        guard case .string(let toolName)? = object["tool_name"] else {
            throw validationError("tool_name must be a string.")
        }
        guard case .object(let arguments)? = object["arguments"] else {
            throw validationError("arguments must be a JSON object.")
        }

        switch toolName {
        case "set_temperature":
            try validateArgumentKeys(arguments, expected: ["temperature"])
            guard case .number? = arguments["temperature"] else {
                throw validationError("set_temperature.arguments.temperature must be a number.")
            }
        case "change_volume":
            try validateArgumentKeys(arguments, expected: ["direction"])
            guard case .string(let direction)? = arguments["direction"],
                  ["up", "down"].contains(direction)
            else {
                throw validationError("change_volume.arguments.direction must be \"up\" or \"down\".")
            }
        case "navigate":
            try validateArgumentKeys(arguments, expected: ["destination"])
            guard case .string(let destination)? = arguments["destination"],
                  destination.isEmpty == false,
                  destination == destination.lowercased()
            else {
                throw validationError("navigate.arguments.destination must be a lowercase string.")
            }
        default:
            throw validationError("Unsupported tool_name: \(toolName).")
        }
    }

    private static func validateArgumentKeys(
        _ arguments: [String: ToolCallJSONValue],
        expected: Set<String>
    ) throws {
        guard Set(arguments.keys) == expected else {
            throw validationError("arguments must contain only \(expected.sorted().joined(separator: ", ")).")
        }
    }

    private static func validationError(_ message: String) -> NSError {
        NSError(
            domain: "ToolCallJSON",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum ToolCallPromptBuilder {
    private static let outputContract = """
    Convert short vehicle, climate, media, and navigation commands into strict JSON action objects.
    Do not output a transcript, Markdown, code fences, prose, explanations, or extra keys.
    Return exactly one JSON object.
    The answer must start with { and end with }.

    Required schema:
    {"tool_name":"...","arguments":{...}}

    Supported tools:
    - set_temperature: use for climate temperature commands. Return {"tool_name":"set_temperature","arguments":{"temperature":21}} where temperature is a number.
    - change_volume: use for volume up or volume down commands. Return {"tool_name":"change_volume","arguments":{"direction":"down"}} where direction is "up" or "down".
    - navigate: use for navigation commands. Return {"tool_name":"navigate","arguments":{"destination":"home"}} where destination is a lowercase string.

    If the command includes polite filler words, ignore them and return the matching tool call.
    Intent rules:
    - If the command mentions volume, loud, louder, quiet, quieter, mute, or sound, choose change_volume.
    - Only choose navigate when the command asks to go, drive, route, or navigate to a destination.
    - Never map "volume down" or "too loud" to navigate.
    """

    private static let examples = """
    Examples:
    Spoken or written command: set temperature to 21 degrees
    Output: {"tool_name":"set_temperature","arguments":{"temperature":21}}

    Spoken or written command: volume down
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Spoken or written command: hey, volume down
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Spoken or written command: it's too loud, volume down
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Spoken or written command: navigate home
    Output: {"tool_name":"navigate","arguments":{"destination":"home"}}
    """

    static let systemPrompt = """
    \(outputContract)

    \(examples)
    """

    static let speechToToolSystemPrompt = """
    Perform ASR.
    """

    static func textToToolUserPrompt(transcript: String) -> String {
        """
        \(outputContract)

        \(examples)

        Convert this transcript into one tool-call JSON object.
        Return only the JSON object.

        Transcript:
        \(transcript)
        """
    }

    static func localTextToToolPrompt(transcript: String) -> String {
        """
        You are a deterministic function-calling classifier.
        Read the command transcript and output exactly one JSON object.
        Do not explain your answer.

        \(outputContract)

        \(examples)

        Command transcript:
        \(transcript)

        JSON:
        """
    }

    static func speechToToolUserPrompt() -> String {
        """
        \(outputContract)

        \(examples)

        Transcribe this audio. Do not return the transcript.
        Convert the recognized command into the JSON action object instead.
        Return only the JSON object.
        """
    }
}

enum ToolCallTranscriptHeuristics {
    static func forcedToolCallJSON(for transcript: String) -> String? {
        let normalized = normalize(transcript)
        guard containsAny(
            in: normalized,
            terms: ["volume", "loud", "louder", "quiet", "quieter", "mute", "sound"]
        ) else {
            return nil
        }

        if containsAny(in: normalized, terms: ["down", "lower", "reduce", "quieter", "quiet", "loud"]) {
            return #"{"tool_name":"change_volume","arguments":{"direction":"down"}}"#
        }
        if containsAny(in: normalized, terms: ["up", "raise", "increase", "louder"]) {
            return #"{"tool_name":"change_volume","arguments":{"direction":"up"}}"#
        }
        return nil
    }

    static func correctedToolCallJSON(rawOutput: String, transcript: String) -> String {
        guard let forced = forcedToolCallJSON(for: transcript) else {
            return rawOutput
        }
        let generated = ToolCallJSON.parseAndValidate(from: rawOutput)
        let expected = ToolCallJSON.parseAndValidate(from: forced)
        guard generated.canonicalJSON != expected.canonicalJSON else {
            return rawOutput
        }
        return forced
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func containsAny(in text: String, terms: [String]) -> Bool {
        terms.contains { term in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b", options: .regularExpression) != nil
        }
    }
}
