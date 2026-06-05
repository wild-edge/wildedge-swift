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
    Return raw JSON only. First character must be { and last character must be }. No transcript, prose, Markdown, ```json fence, explanation, reasoning, <think> tags, or extra keys. Do not think out loud. Return exactly one of these schemas: {"tool_name":"set_temperature","arguments":{"temperature":21}} or {"tool_name":"change_volume","arguments":{"direction":"down"}} or {"tool_name":"navigate","arguments":{"destination":"home"}} or {"tool_name":"unknown","arguments":{}}. set_temperature: use only for climate, temperature, warmer, cooler, heat, cold, AC, or air conditioning; arguments must contain only temperature; if the command contains a numeric temperature, copy exactly that number; never replace a spoken number with 19; never output ac or any key except temperature. change_volume: arguments must contain only direction; too loud/quieter/down=>down; too quiet/louder/can't hear/up=>up. navigate: arguments must contain only destination; destination is lowercase place only; strip please, now, and filler words. unknown: arguments must be empty.
    """

    static let systemPrompt = compactSystemPrompt

    static let speechToToolSystemPrompt = """
    Perform ASR.
    """

    static func textToToolUserPrompt(transcript: String) -> String {
        """
        Command:
        \(transcript)

        /no_think
        Raw JSON only. Start with { and stop after the first matching }. No markdown fence, explanation, <think> tag, or extra keys.
        JSON:
        """
    }

    static func chatTextToToolUserPrompt(transcript: String) -> String {
        """
        Command:
        \(transcript)

        /no_think
        Raw JSON only. Start with { and stop after the first matching }. No markdown fence, explanation, <think> tag, or extra keys.
        JSON:
        """
    }

    static let localTextToToolPromptPrefix = """
    \(compactSystemPrompt)

    Command:
    """

    static let localTextToToolPromptSuffix = """

    /no_think
    Raw JSON only. Start with { and stop after the first matching }. No markdown fence, explanation, <think> tag, or extra keys.
    JSON:
    """

    static func localTextToToolPrompt(transcript: String) -> String {
        localTextToToolPromptPrefix + transcript + localTextToToolPromptSuffix
    }

    static func speechToToolUserPrompt() -> String {
        """
        \(compactSystemPrompt)
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

        if let correctedNavigation = correctedNavigationToolCallJSON(rawOutput: normalizedOutput) {
            return correctedNavigation
        }

        if ToolCallJSON.parseAndValidate(from: normalizedOutput).parsedSuccessfully == false,
           let inferred = inferredToolCallJSON(for: transcript) {
            return inferred
        }

        return normalizedOutput
    }

    private static func inferredToolCallJSON(for transcript: String) -> String? {
        let normalized = normalize(transcript)
        let hasClimateIntent = containsAny(
            in: normalized,
            terms: ["temperature", "warmer", "cooler", "heat", "cold", "ac", "air conditioning"]
        )
        if hasClimateIntent, let temperature = explicitTemperature(in: normalized) {
            return #"{"tool_name":"set_temperature","arguments":{"temperature":\#(temperature)}}"#
        }
        if hasClimateIntent {
            return #"{"tool_name":"set_temperature","arguments":{"temperature":21}}"#
        }
        if let volume = forcedToolCallJSON(for: transcript) {
            return volume
        }
        if let destination = navigationDestination(in: normalized) {
            let quotedDestination = ToolCallJSONValue.string(destination).canonicalString
            return #"{"tool_name":"navigate","arguments":{"destination":\#(quotedDestination)}}"#
        }
        return #"{"tool_name":"unknown","arguments":{}}"#
    }

    private static func explicitTemperature(in normalizedTranscript: String) -> Int? {
        let pattern = #"(?:^|\s)([1-3]?\d)(?:\s*(?:degrees?|celsius))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(normalizedTranscript.startIndex..<normalizedTranscript.endIndex, in: normalizedTranscript)
        guard let match = regex.firstMatch(in: normalizedTranscript, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: normalizedTranscript),
              let value = Int(normalizedTranscript[matchRange]),
              (10...35).contains(value)
        else {
            return nil
        }
        return value
    }

    private static func navigationDestination(in normalizedTranscript: String) -> String? {
        guard containsAny(
            in: normalizedTranscript,
            terms: ["navigate", "directions", "route", "drive", "go to", "get to", "let's go", "lets go"]
        ) else {
            return nil
        }

        let patterns = [
            #"navigate(?: to)? (.+)"#,
            #"directions(?: to)? (.+)"#,
            #"route(?: to)? (.+)"#,
            #"drive to (.+)"#,
            #"go to (.+)"#,
            #"get to (.+)"#,
            #"let'?s go(?: to)? (.+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(normalizedTranscript.startIndex..<normalizedTranscript.endIndex, in: normalizedTranscript)
            guard let match = regex.firstMatch(in: normalizedTranscript, range: range),
                  match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: normalizedTranscript)
            else {
                continue
            }
            let destination = cleanedNavigationDestination(String(normalizedTranscript[matchRange]))
            if destination.isEmpty == false {
                return destination
            }
        }
        return nil
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
