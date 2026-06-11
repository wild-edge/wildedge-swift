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
        var lastError: String?
        for searchText in searchTexts {
            for jsonObjectText in extractJSONObjectCandidates(from: searchText) {
                sawJSONObject = true
                do {
                    let value = try parseAndValidateJSONObject(jsonObjectText)
                    return ToolCallParseResult(value: value, error: nil)
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }

        if let functionCallValue = firstFunctionCallValue(from: searchTexts) {
            return ToolCallParseResult(value: functionCallValue, error: nil)
        }

        guard sawJSONObject else {
            return ToolCallParseResult(value: nil, error: "No JSON object found.")
        }
        return ToolCallParseResult(
            value: nil,
            error: lastError ?? "No valid tool-call JSON object found."
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
        if let functionCallValue = firstFunctionCallValue(from: uniqueSearchTexts(from: trimmed)) {
            return functionCallValue.canonicalString
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
        text.removingTaggedBlocks(named: "think")
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
        return try normalizedToolCallValue(from: value)
    }

    private static func uniqueSearchTexts(from text: String) -> [String] {
        let withoutThinkBlocks = text.removingTaggedBlocks(named: "think")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFunctionTags = withoutThinkBlocks
            .removingKnownFunctionCallTags()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var texts: [String] = []
        for candidate in [withoutFunctionTags, withoutThinkBlocks, text] {
            guard candidate.isEmpty == false,
                  texts.contains(candidate) == false else {
                continue
            }
            texts.append(candidate)
        }
        return texts.isEmpty ? [text] : texts
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
                if depth <= 0 {
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

    private static func normalizedToolCallValue(from value: ToolCallJSONValue) throws -> ToolCallJSONValue {
        switch value {
        case .object(let object):
            if isCanonicalToolCallObject(object) {
                let canonical = ToolCallJSONValue.object(object)
                try validateToolCall(canonical)
                return canonical
            }
            if let nested = nestedToolCallValue(in: object) {
                return try normalizedToolCallValue(from: nested)
            }
            if let toolName = toolName(in: object) {
                let canonicalName = try canonicalToolName(toolName)
                let arguments = try canonicalArguments(
                    for: canonicalName,
                    rawArguments: rawArguments(in: object),
                    fallbackObject: object
                )
                let canonical = ToolCallJSONValue.object([
                    "tool_name": .string(canonicalName),
                    "arguments": arguments
                ])
                try validateToolCall(canonical)
                return canonical
            }
            throw validationError("Tool call must contain a supported tool name.")
        case .array(let array):
            for item in array {
                if let value = try? normalizedToolCallValue(from: item) {
                    return value
                }
            }
            throw validationError("No valid tool call found in array.")
        default:
            throw validationError("Tool call must be a JSON object.")
        }
    }

    private static func isCanonicalToolCallObject(_ object: [String: ToolCallJSONValue]) -> Bool {
        Set(object.keys) == ["tool_name", "arguments"]
    }

    private static func nestedToolCallValue(in object: [String: ToolCallJSONValue]) -> ToolCallJSONValue? {
        for key in ["function_call", "functionCall", "tool_call", "toolCall", "call", "action"] {
            if let value = object[key] {
                return value
            }
        }
        for key in ["function", "tool"] {
            if case .object? = object[key] {
                return object[key]
            }
        }
        for key in ["tool_calls", "toolCalls", "calls", "actions"] {
            if case .array? = object[key] {
                return object[key]
            }
        }
        return nil
    }

    private static func toolName(in object: [String: ToolCallJSONValue]) -> String? {
        for key in ["tool_name", "toolName", "name", "function_name", "functionName", "function", "tool", "action"] {
            if case .string(let name)? = object[key] {
                return name
            }
        }
        return nil
    }

    private static func rawArguments(in object: [String: ToolCallJSONValue]) -> ToolCallJSONValue? {
        for key in ["arguments", "args", "parameters", "params", "kwargs", "input"] {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func canonicalToolName(_ name: String) throws -> String {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()

        switch normalized {
        case "set_temperature", "settemperature", "temperature", "climate", "set_climate":
            return "set_temperature"
        case "change_volume", "changevolume", "volume", "set_volume", "adjust_volume", "audio_volume":
            return "change_volume"
        case "navigate", "navigation", "navigate_to", "get_directions", "directions", "route":
            return "navigate"
        case "unknown", "none", "no_tool":
            return "unknown"
        default:
            throw validationError("Unsupported tool_name: \(name).")
        }
    }

    private static func canonicalArguments(
        for toolName: String,
        rawArguments: ToolCallJSONValue?,
        fallbackObject: [String: ToolCallJSONValue]
    ) throws -> ToolCallJSONValue {
        let argumentObject = try argumentObject(from: rawArguments)
            ?? fallbackArguments(from: fallbackObject)

        switch toolName {
        case "set_temperature":
            guard let temperature = argumentObject["temperature"].flatMap(numberValue) else {
                throw validationError("set_temperature.arguments.temperature must be a number.")
            }
            return .object(["temperature": .number(temperature)])
        case "change_volume":
            guard let rawDirection = argumentObject["direction"].flatMap(stringValue),
                  let direction = canonicalVolumeDirection(rawDirection) else {
                throw validationError("change_volume.arguments.direction must be \"up\" or \"down\".")
            }
            return .object(["direction": .string(direction)])
        case "navigate":
            guard let destination = argumentObject["destination"].flatMap(stringValue)
                    ?? argumentObject["place"].flatMap(stringValue)
                    ?? argumentObject["location"].flatMap(stringValue),
                  destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw validationError("navigate.arguments.destination must be a lowercase string.")
            }
            return .object(["destination": .string(cleanedDestination(destination))])
        case "unknown":
            return .object([:])
        default:
            throw validationError("Unsupported tool_name: \(toolName).")
        }
    }

    private static func argumentObject(
        from value: ToolCallJSONValue?
    ) throws -> [String: ToolCallJSONValue]? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            return object
        case .array(let array):
            for item in array {
                if case .object(let object) = item {
                    return object
                }
            }
            return nil
        case .string(let string):
            if let object = jsonObjectValue(from: string) {
                return object
            }
            return keyValueArguments(from: string)
        default:
            return nil
        }
    }

    private static func fallbackArguments(
        from object: [String: ToolCallJSONValue]
    ) -> [String: ToolCallJSONValue] {
        let reservedKeys: Set<String> = [
            "tool_name", "toolName", "name", "function_name", "functionName", "function",
            "tool", "action", "arguments", "args", "parameters", "params", "kwargs", "input"
        ]
        return object.filter { reservedKeys.contains($0.key) == false }
    }

    private static func jsonObjectValue(from text: String) -> [String: ToolCallJSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = try? ToolCallJSONValue(any: object),
              case .object(let parsed) = value else {
            return nil
        }
        return parsed
    }

    private static func firstFunctionCallValue(from searchTexts: [String]) -> ToolCallJSONValue? {
        for searchText in searchTexts {
            for functionCall in extractFunctionCallCandidates(from: searchText) {
                if let value = try? normalizedToolCallValue(from: functionCall) {
                    return value
                }
            }
        }
        return nil
    }

    private static func extractFunctionCallCandidates(from text: String) -> [ToolCallJSONValue] {
        let names = [
            "set_temperature", "setTemperature", "temperature",
            "change_volume", "changeVolume", "volume",
            "navigate", "navigation", "unknown"
        ]
        var candidates: [ToolCallJSONValue] = []
        for name in names {
            var searchRange = text.startIndex..<text.endIndex
            while let nameRange = text.range(of: name, options: [.caseInsensitive], range: searchRange) {
                let afterName = nameRange.upperBound..<text.endIndex
                if let openParen = text[afterName].firstIndex(of: "("),
                   let closeParen = matchingCloseParen(startingAt: openParen, in: text) {
                    let rawArguments = String(text[text.index(after: openParen)..<closeParen])
                    candidates.append(.object([
                        "name": .string(name),
                        "arguments": .object(functionArguments(from: rawArguments, functionName: name))
                    ]))
                    searchRange = text.index(after: closeParen)..<text.endIndex
                    continue
                }

                if let taggedCandidate = functionCallCandidateWithoutParentheses(
                    name: name,
                    text: text,
                    nameEndIndex: nameRange.upperBound
                ) {
                    candidates.append(taggedCandidate.value)
                    searchRange = taggedCandidate.nextIndex..<text.endIndex
                    continue
                }

                searchRange = nameRange.upperBound..<text.endIndex
            }
        }
        return candidates
    }

    private static func functionCallCandidateWithoutParentheses(
        name: String,
        text: String,
        nameEndIndex: String.Index
    ) -> (value: ToolCallJSONValue, nextIndex: String.Index)? {
        let trailingStart = text[nameEndIndex...]
            .firstIndex { $0.isWhitespace == false && $0 != ":" }
            ?? nameEndIndex

        if trailingStart < text.endIndex,
           text[trailingStart] == "{",
           let objectEndIndex = endOfJSONObject(startingAt: trailingStart, in: text) {
            let rawArguments = String(text[trailingStart..<objectEndIndex])
            return (
                .object([
                    "name": .string(name),
                    "arguments": .object(functionArguments(from: rawArguments, functionName: name))
                ]),
                objectEndIndex
            )
        }

        let boundary = text[trailingStart...].firstIndex { character in
            character == "<" || character == "\n" || character == ";" || character == ")"
        } ?? text.endIndex
        let rawArguments = String(text[trailingStart..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawArguments.isEmpty == false else {
            return nil
        }
        return (
            .object([
                "name": .string(name),
                "arguments": .object(functionArguments(from: rawArguments, functionName: name))
            ]),
            boundary
        )
    }

    private static func matchingCloseParen(
        startingAt openParen: String.Index,
        in text: String
    ) -> String.Index? {
        var depth = 0
        var quote: Character?
        var isEscaped = false
        var index = openParen
        while index < text.endIndex {
            let character = text[index]
            if let activeQuote = quote {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func functionArguments(
        from text: String,
        functionName: String
    ) -> [String: ToolCallJSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonObjectValue(from: trimmed) {
            return object
        }
        let keyValues = keyValueArguments(from: trimmed)
        if keyValues.isEmpty == false {
            return keyValues
        }
        guard trimmed.isEmpty == false else {
            return [:]
        }

        switch try? canonicalToolName(functionName) {
        case "set_temperature":
            return ["temperature": primitiveValue(from: trimmed)]
        case "change_volume":
            return ["direction": primitiveValue(from: trimmed)]
        case "navigate":
            return ["destination": primitiveValue(from: trimmed)]
        default:
            return [:]
        }
    }

    private static func keyValueArguments(from text: String) -> [String: ToolCallJSONValue] {
        var arguments: [String: ToolCallJSONValue] = [:]
        for field in splitArguments(text) {
            let separators = ["=", ":"]
            guard let separator = separators.compactMap({ field.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
                continue
            }
            let key = field[..<separator.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let rawValue = field[separator.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.isEmpty == false else { continue }
            arguments[key] = primitiveValue(from: rawValue)
        }
        return arguments
    }

    private static func splitArguments(_ text: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false
        for character in text {
            if let activeQuote = quote {
                current.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == activeQuote {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                fields.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if last.isEmpty == false {
            fields.append(last)
        }
        return fields
    }

    private static func primitiveValue(from text: String) -> ToolCallJSONValue {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let double = Double(trimmed), double.isFinite {
            if double.rounded() == double {
                return .number(String(Int64(double)))
            }
            return .number(String(format: "%.15g", double))
        }
        return .string(trimmed)
    }

    private static func stringValue(_ value: ToolCallJSONValue) -> String? {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number
        default:
            return nil
        }
    }

    private static func numberValue(_ value: ToolCallJSONValue) -> String? {
        switch value {
        case .number(let number):
            return number
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let double = Double(trimmed), double.isFinite else { return nil }
            if double.rounded() == double {
                return String(Int64(double))
            }
            return String(format: "%.15g", double)
        default:
            return nil
        }
    }

    private static func canonicalVolumeDirection(_ direction: String) -> String? {
        let normalized = direction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["up", "increase", "raise", "louder", "unmute"].contains(normalized) {
            return "up"
        }
        if ["down", "decrease", "lower", "quieter", "mute"].contains(normalized) {
            return "down"
        }
        return nil
    }

    private static func cleanedDestination(_ destination: String) -> String {
        var cleaned = destination
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for filler in ["please", "pls", "thanks", "thank you", "now"] {
            if cleaned.hasPrefix("\(filler) ") {
                cleaned = String(cleaned.dropFirst(filler.count + 1))
            }
            if cleaned.hasSuffix(" \(filler)") {
                cleaned = String(cleaned.dropLast(filler.count + 1))
            }
        }
        return cleaned
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
    private static let outputContract = """
    You convert short in-car voice or text commands into exactly one JSON tool call.

    Output contract:
    - Return only valid JSON.
    - Return exactly one JSON object, never an array, list, or multiple calls.
    - Stop immediately after the closing brace of that JSON object.
    - Do not include Markdown, code fences, prose, transcripts, explanations, reasoning, scratchpad text, <think> tags, or extra keys.
    - The JSON must match this shape:
      {"tool_name":"...","arguments":{...}}

    Available tools:

    1. set_temperature
    Use when the command is about cabin climate, temperature, heat, cold, warmth, cooling, heating, AC, air conditioning, or making the car warmer or cooler.

    Arguments:
    {"temperature": number}

    If the user gives a specific temperature, use that number.
    Example: "set temperature to 21 degrees"
    Output: {"tool_name":"set_temperature","arguments":{"temperature":21}}

    2. change_volume
    Use when the command is about audio loudness, volume, sound level, being too loud, too quiet, louder, quieter, turning sound up, turning sound down, muting, or unmuting.

    Arguments:
    {"direction":"up" | "down"}

    Map louder, too quiet, can't hear, turn it up, and volume up to "up".
    Map quieter, too loud, turn it down, lower the sound, and volume down to "down".

    Example: "it's too loud"
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    3. navigate
    Use when the command is about navigation, routing, directions, going somewhere, driving somewhere, finding a route, or asking how to get to a destination.

    Arguments:
    {"destination": lowercase string}

    Extract only the destination.
    Remove polite or timing filler from the destination, especially leading or trailing words such as "please", "pls", "thanks", "thank you", or "now".
    Example: "navigate home, please"
    Output: {"tool_name":"navigate","arguments":{"destination":"home"}}
    Example: "how do I get to the airport"
    Output: {"tool_name":"navigate","arguments":{"destination":"airport"}}

    General rules:
    - Ignore polite filler words such as "hey", "please", "pls", "thanks", "thank you", "can you", "could you", or "I want to".
    - Never include polite filler words in arguments. For navigation, the destination must be only the place name.
    - Prefer the tool whose real-world domain best matches the command:
      - loudness or sound level means audio, so use change_volume.
      - temperature, heat, cold, AC, or air means climate, so use set_temperature.
      - routes, directions, driving, or going somewhere means navigation, so use navigate.
    - Do not choose navigate unless the command asks for travel, routing, directions, or going to a destination.
    - If no supported tool clearly matches, return:
      {"tool_name":"unknown","arguments":{}}
    """

    private static let examples = """
    Examples:

    Command: set temperature to 21 degrees
    Output: {"tool_name":"set_temperature","arguments":{"temperature":21}}

    Command: make it warmer
    Output: {"tool_name":"set_temperature","arguments":{"temperature":22}}

    Command: turn on the AC
    Output: {"tool_name":"set_temperature","arguments":{"temperature":19}}

    Command: volume down
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Command: hey, it's too loud
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Command: its too loud, volume down
    Output: {"tool_name":"change_volume","arguments":{"direction":"down"}}

    Command: I can't hear it
    Output: {"tool_name":"change_volume","arguments":{"direction":"up"}}

    Command: navigate home
    Output: {"tool_name":"navigate","arguments":{"destination":"home"}}

    Command: navigate home, please
    Output: {"tool_name":"navigate","arguments":{"destination":"home"}}

    Command: please navigate home
    Output: {"tool_name":"navigate","arguments":{"destination":"home"}}

    Command: how do I get to central station
    Output: {"tool_name":"navigate","arguments":{"destination":"central station"}}

    Command: drive to work
    Output: {"tool_name":"navigate","arguments":{"destination":"work"}}
    """

    static let compactSystemPrompt = """
    Convert one short in-car command into exactly one JSON object:
    {"tool_name":"...","arguments":{...}}

    Return only JSON. No Markdown, prose, reasoning, <think> text, <start_function_call> tags, native function-call syntax, arrays, or multiple calls. Stop after the closing brace.

    Tools:
    - set_temperature {"temperature":number}: climate, temperature, heat, cold, warm, cool, AC, air conditioning.
    - change_volume {"direction":"up"|"down"}: audio loudness, volume, sound, louder, quieter, mute, unmute. Map "too loud", "volume down", "lower sound" to "down"; "too quiet", "can't hear", "volume up" to "up".
    - navigate {"destination":lowercase string}: routing, directions, drive/go/navigate to a place. Destination is only the place name; remove filler like please, pls, thanks, thank you, now.
    - unknown {}: no supported tool clearly matches.

    Examples:
    set temperature to 21 degrees -> {"tool_name":"set_temperature","arguments":{"temperature":21}}
    volume down -> {"tool_name":"change_volume","arguments":{"direction":"down"}}
    I can't hear it -> {"tool_name":"change_volume","arguments":{"direction":"up"}}
    navigate home, please -> {"tool_name":"navigate","arguments":{"destination":"home"}}
    """

    static let systemPrompt = compactSystemPrompt

    static let speechToToolSystemPrompt = "Perform ASR."

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

    static let toolCallJSONSchema = """
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["tool_name", "arguments"],
      "properties": {
        "tool_name": {
          "type": "string",
          "enum": ["set_temperature", "change_volume", "navigate", "unknown"]
        },
        "arguments": {
          "type": "object"
        }
      }
    }
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

    static func localTextToToolPrompt(transcript: String) -> String {
        """
        \(compactSystemPrompt)

        Command:
        \(transcript)

        Output exactly one JSON object and stop after its closing brace.
        """
    }

    static func speechToToolUserPrompt() -> String {
        """
        You convert one spoken in-car command into exactly one JSON object.

        Return only valid JSON. No transcript, prose, Markdown, code fences, reasoning, or extra keys. Stop after the JSON object.

        Required shape:
        {"tool_name":"set_temperature|change_volume|navigate|unknown","arguments":{}}

        Choose exactly one tool:
        - set_temperature: use for cabin temperature, heat, cold, warmer, cooler, AC, air conditioning. Arguments: {"temperature":number}. If a number is spoken, use it.
        - change_volume: use for audio volume, sound, loud, quiet, louder, quieter, mute, unmute. Arguments: {"direction":"up"|"down"}. Map "too loud", "quieter", "lower", "volume down" to "down". Map "too quiet", "can't hear", "louder", "volume up" to "up".
        - navigate: use only for travel, routing, directions, driving, or going to a destination. Arguments: {"destination":"lowercase place"}. Remove filler like please, now, thanks.
        - unknown: use when no tool clearly matches. Arguments: {}.

        Do not choose navigate just because a place word appears. Choose navigate only when the command asks to go, drive, route, navigate, or get directions.

        Examples:
        "temperature 21 degrees" -> {"tool_name":"set_temperature","arguments":{"temperature":21}}
        "it's too loud, volume down" -> {"tool_name":"change_volume","arguments":{"direction":"down"}}
        "I can't hear it" -> {"tool_name":"change_volume","arguments":{"direction":"up"}}
        "let's go home" -> {"tool_name":"navigate","arguments":{"destination":"home"}}
        """
    }

    static func qwenASRSpeechToToolUserPrompt() -> String {
        """
        Audio command:
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

        if containsAny(in: normalized, terms: ["up", "raise", "increase", "louder"])
            || normalized.contains("too quiet")
            || normalized.contains("can't hear")
            || normalized.contains("cant hear")
            || normalized.contains("cannot hear") {
            return #"{"tool_name":"change_volume","arguments":{"direction":"up"}}"#
        }
        if containsAny(in: normalized, terms: ["down", "lower", "reduce", "quieter"])
            || normalized.contains("too loud") {
            return #"{"tool_name":"change_volume","arguments":{"direction":"down"}}"#
        }
        return nil
    }

    static func correctedToolCallJSON(rawOutput: String, transcript: String) -> String {
        let normalizedOutput = ToolCallJSON.firstValidToolCallJSONString(from: rawOutput) ?? rawOutput

        if let forced = forcedToolCallJSON(for: transcript) {
            let generated = ToolCallJSON.parseAndValidate(from: normalizedOutput)
            let expected = ToolCallJSON.parseAndValidate(from: forced)
            guard generated.canonicalJSON != expected.canonicalJSON else {
                return normalizedOutput
            }
            return forced
        }

        if ToolCallJSON.parseAndValidate(from: normalizedOutput).value == nil,
           let inferred = inferredToolCallJSON(fromTranscript: transcript) {
            return inferred
        }

        if let correctedNavigation = correctedNavigationToolCallJSON(rawOutput: normalizedOutput) {
            return correctedNavigation
        }

        return normalizedOutput
    }

    private static func inferredToolCallJSON(fromTranscript transcript: String) -> String? {
        let normalized = normalize(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard normalized.isEmpty == false else { return nil }

        if containsAny(in: normalized, terms: ["temperature", "temp", "degrees", "warmer", "cooler", "cold", "hot", "heat", "ac"]) {
            let temperature = firstNumber(in: normalized)
                ?? (containsAny(in: normalized, terms: ["cooler", "cold", "ac"]) ? 19 : 22)
            return #"{"tool_name":"set_temperature","arguments":{"temperature":\#(temperature)}}"#
        }

        if let forced = forcedToolCallJSON(for: normalized) {
            return forced
        }

        if containsAny(in: normalized, terms: ["navigate", "directions", "drive", "go", "route"])
            || normalized.contains("get to") {
            let destination = cleanedNavigationDestination(navigationDestination(from: normalized))
            guard destination.isEmpty == false else { return nil }
            let quotedDestination = ToolCallJSONValue.string(destination).canonicalString
            return #"{"tool_name":"navigate","arguments":{"destination":\#(quotedDestination)}}"#
        }

        return nil
    }

    private static func firstNumber(in text: String) -> Int? {
        guard let range = text.range(of: #"\b\d{1,3}\b"#, options: .regularExpression),
              let value = Int(text[range])
        else {
            return nil
        }
        return value
    }

    private static func navigationDestination(from text: String) -> String {
        let prefixes = [
            "how do i get to ",
            "can you navigate to ",
            "could you navigate to ",
            "please navigate to ",
            "navigate to ",
            "navigate ",
            "directions to ",
            "drive to ",
            "route to ",
            "let's go to ",
            "lets go to ",
            "let's go ",
            "lets go ",
            "go to ",
            "go "
        ]
        for prefix in prefixes where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        if let range = text.range(of: " get to ") {
            return String(text[range.upperBound...])
        }
        return text
    }

    private static func correctedNavigationToolCallJSON(rawOutput: String) -> String? {
        let generated = ToolCallJSON.parseAndValidate(from: rawOutput)
        guard case .object(let object)? = generated.value,
              case .string("navigate")? = object["tool_name"],
              case .object(let arguments)? = object["arguments"],
              case .string(let destination)? = arguments["destination"]
        else {
            return nil
        }

        let cleanedDestination = cleanedNavigationDestination(destination)
        guard cleanedDestination.isEmpty == false,
              cleanedDestination != destination
        else {
            return nil
        }

        let quotedDestination = ToolCallJSONValue.string(cleanedDestination).canonicalString
        return #"{"tool_name":"navigate","arguments":{"destination":\#(quotedDestination)}}"#
    }

    private static func cleanedNavigationDestination(_ destination: String) -> String {
        var cleaned = normalize(destination)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))

        var didChange = true
        while didChange {
            didChange = false
            for phrase in leadingDestinationFillers where cleaned.hasPrefix(phrase) {
                cleaned = String(cleaned.dropFirst(phrase.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                didChange = true
            }
            for phrase in trailingDestinationFillers where cleaned.hasSuffix(phrase) {
                cleaned = String(cleaned.dropLast(phrase.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                didChange = true
            }
        }
        return cleaned
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static let leadingDestinationFillers = [
        "please ",
        "pls ",
        "thanks ",
        "thank you "
    ]

    private static let trailingDestinationFillers = [
        " please",
        " pls",
        " thanks",
        " thank you",
        " now"
    ]

    private static func containsAny(in text: String, terms: [String]) -> Bool {
        terms.contains { term in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b", options: .regularExpression) != nil
        }
    }
}

private extension String {
    func removingTaggedBlocks(named tagName: String) -> String {
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

        return result
    }

    func removingKnownFunctionCallTags() -> String {
        var result = self
        let tags = [
            "<start_function_call>",
            "<end_function_call>",
            "<function_call>",
            "</function_call>",
            "<tool_call>",
            "</tool_call>",
            "<start_tool_call>",
            "<end_tool_call>",
            "<start_parameter>",
            "<end_parameter>",
            "<start_argument>",
            "<end_argument>",
            "<separator>",
            "<sep>"
        ]
        for tag in tags {
            result = result.replacingOccurrences(
                of: tag,
                with: " ",
                options: [.caseInsensitive]
            )
        }
        return result
    }
}
