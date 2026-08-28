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

        let searchTexts = uniqueSearchTexts(from: trimmed)
        var sawJSONObject = false
        var firstError: String?
        for searchText in searchTexts {
            for jsonObjectText in extractJSONObjectCandidates(from: searchText) {
                sawJSONObject = true
                do {
                    let value = try parseAndValidateJSONObject(jsonObjectText)
                    return ToolCallParseResult(value: value, error: nil)
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
        }

        guard sawJSONObject else {
            return ToolCallParseResult(value: nil, error: "No JSON object found.")
        }
        return ToolCallParseResult(
            value: nil,
            error: firstError ?? "No valid tool-call JSON object found."
        )
    }

    static func firstValidToolCallJSONString(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        for searchText in uniqueSearchTexts(from: trimmed) {
            for jsonObjectText in extractJSONObjectCandidates(from: searchText) {
                if let value = try? parseAndValidateJSONObject(jsonObjectText) {
                    return value.canonicalString
                }
            }
        }
        return nil
    }

    static func firstJSONObjectString(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        for searchText in uniqueSearchTexts(from: trimmed) {
            if let jsonObjectText = extractJSONObjectCandidates(from: searchText).first {
                return jsonObjectText
            }
        }
        return nil
    }

    static func rootJSONObjectString(from text: String) -> String? {
        for searchText in uniqueSearchTexts(from: text) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" else { continue }
            if let endIndex = endOfJSONObject(startingAt: trimmed.startIndex, in: trimmed) {
                return String(trimmed[trimmed.startIndex..<endIndex])
            }
        }
        return nil
    }

    static func completedValidRootToolCallJSONString(from text: String) -> String? {
        for searchText in uniqueSearchTexts(from: text) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" else { continue }

            if let rootJSONObject = rootJSONObjectString(from: trimmed),
               let value = try? parseAndValidateJSONObject(rootJSONObject) {
                return value.canonicalString
            }

            guard let completionSuffix = rootJSONObjectCompletionSuffix(from: trimmed) else {
                continue
            }
            let completed = trimmed + completionSuffix
            if let value = try? parseAndValidateJSONObject(completed) {
                return value.canonicalString
            }
        }
        return nil
    }

    static func textWithoutThinkBlocks(from text: String) -> String {
        text.removingTaggedBlocks(named: "think", removeUnterminated: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func parseAndValidateJSONObject(_ text: String) throws -> ToolCallJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw validationError("JSON output is not UTF-8.")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        let value = try ToolCallJSONValue(any: object)
        try validateToolCall(value)
        return value
    }

    private static func uniqueSearchTexts(from text: String) -> [String] {
        let withoutThinkBlocks = text.removingTaggedBlocks(named: "think")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard withoutThinkBlocks.isEmpty == false,
              withoutThinkBlocks != text
        else {
            return [text]
        }
        return [withoutThinkBlocks, text]
    }

    private static func extractJSONObjectCandidates(from text: String) -> [String] {
        var candidates: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "{",
               let endIndex = endOfJSONObject(startingAt: index, in: text) {
                candidates.append(String(text[index..<endIndex]))
            }
            index = text.index(after: index)
        }
        return candidates
    }

    private static func endOfJSONObject(
        startingAt startIndex: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = startIndex

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
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return text.index(after: index)
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func rootJSONObjectCompletionSuffix(from text: String) -> String? {
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
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth < 0 {
                    return nil
                }
                if depth == 0 {
                    return nil
                }
            }

            index = text.index(after: index)
        }

        guard isInString == false, depth > 0 else {
            return nil
        }
        return String(repeating: "}", count: depth)
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
        case "unknown":
            try validateArgumentKeys(arguments, expected: [])
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
    static let compactSystemPrompt = """
    Return exactly one JSON object and then stop.
    Output JSON only: no transcript, prose, Markdown, code fence, reasoning, or extra keys.
    Schema: {"tool_name":"<tool_name>","arguments":{...}}
    Valid tool_name values: set_temperature, change_volume, navigate, unknown.
    Argument schemas:
    set_temperature: {"temperature": number}
    change_volume: {"direction": "up" | "down"}
    navigate: {"destination": string}
    unknown: {}
    If the request is unsupported, unclear, or missing a required argument, use unknown.
    """

    static let systemPrompt = compactSystemPrompt

    static let speechToToolSystemPrompt = """
    Convert the spoken audio command into exactly one JSON tool call.
    Output JSON only: no transcript, prose, Markdown, code fence, reasoning, or extra keys.
    Schema: {"tool_name":"<tool_name>","arguments":{...}}
    Valid tool_name values: set_temperature, change_volume, navigate, unknown.
    Argument schemas:
    set_temperature: {"temperature": number}
    change_volume: {"direction": "up" | "down"}
    navigate: {"destination": string}
    unknown: {}
    If the request is unsupported, unclear, or missing a required argument, use unknown.
    """

    static let qwenASRSpeechToToolSystemPrompt = """
    Convert the spoken audio command into exactly one JSON tool call.
    Output JSON only: no transcript, language tag, prose, Markdown, code fence, reasoning, or extra keys.
    Schema: {"tool_name":"<tool_name>","arguments":{...}}
    Valid tool_name values: set_temperature, change_volume, navigate, unknown.
    Argument schemas:
    set_temperature: {"temperature": number}
    change_volume: {"direction": "up" | "down"}
    navigate: {"destination": string}
    unknown: {}
    If the request is unsupported, unclear, or missing a required argument, use unknown.
    """

    static func textToToolUserPrompt(transcript: String) -> String {
        """
        Command:
        \(transcript)

        Output exactly one JSON object and stop after its closing brace.
        JSON:
        """
    }

    static func chatTextToToolUserPrompt(transcript: String) -> String {
        """
        Command:
        \(transcript)

        Output exactly one JSON object and stop after its closing brace.
        JSON:
        """
    }

    static let localTextToToolPromptPrefix = """
    \(compactSystemPrompt)

    Command:
    """

    static let localTextToToolPromptSuffix = """

    Output exactly one JSON object and stop after its closing brace.
    """

    static func localTextToToolPrompt(transcript: String) -> String {
        localTextToToolPromptPrefix + transcript + localTextToToolPromptSuffix
    }

    static func speechToToolUserPrompt() -> String {
        """
        Audio:
        """
    }

    static func qwenASRSpeechToToolUserPrompt() -> String {
        """
        Audio command:
        """
    }
}

private extension String {
    func removingTaggedBlocks(named tagName: String, removeUnterminated: Bool = false) -> String {
        var result = self
        let startTag = "<\(tagName)>"
        let endTag = "</\(tagName)>"

        while let startRange = result.range(of: startTag, options: [.caseInsensitive]),
              let endRange = result.range(
                of: endTag,
                options: [.caseInsensitive],
                range: startRange.upperBound..<result.endIndex
              ) {
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }

        if removeUnterminated,
           let startRange = result.range(of: startTag, options: [.caseInsensitive]) {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
        }

        return result
    }
}
