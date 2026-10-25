import Foundation

/// Sets or removes top-level keys in another app's JSON settings file (a code editor's settings.json,
/// say) and leaves everything else exactly as it was: other keys, their order, comments, spacing.
/// Files like that are often "JSON with comments", which a JSON parser would refuse or rewrite.
public enum JSONKeyPatch {
    public enum Change: Sendable, Equatable {
        case set(JSONValue)
        case remove
    }

    public struct Result: Sendable, Equatable {
        public var text: String
        /// The keys that were there before, with their values.
        public var before: [String: JSONValue]
        /// The keys that weren't there.
        public var absent: [String]
    }

    public struct Unreadable: LocalizedError {
        public let reason: String
        public var errorDescription: String? { "The file isn't readable JSON (\(reason)), so Orbit left it alone." }
    }

    public static func apply(_ changes: [String: Change], to text: String) throws -> Result {
        var bytes = Array((text.isEmpty ? "{}\n" : text).utf8)
        var before: [String: JSONValue] = [:]
        var absent: [String] = []
        // One key at a time, reading the file afresh each time, so no edit can trip over another.
        for (key, change) in changes.sorted(by: { $0.key < $1.key }) {
            var scanner = Scanner(bytes)
            let object = try scanner.topLevelObject()
            let indent = object.indent(in: bytes)
            guard let index = object.members.firstIndex(where: { $0.key == key }) else {
                absent.append(key)
                guard case .set(let value) = change else { continue }
                let line = "\n\(indent)\(try json(.string(key))): \(try render(value, indent: indent))\(object.members.isEmpty ? "\n" : ",")"
                bytes.insert(contentsOf: Array(line.utf8), at: object.open + 1)
                continue
            }
            let member = object.members[index]
            guard let old = member.value(in: bytes) else { throw Unreadable(reason: "the value of \"\(key)\" isn't plain JSON") }
            before[key] = old
            switch change {
            case .set(let value):
                bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(try render(value, indent: indent).utf8))
            case .remove:
                let cut = removal(of: index, in: object, bytes: bytes)
                bytes.removeSubrange(cut)
            }
        }
        return Result(text: String(decoding: bytes, as: UTF8.self), before: before, absent: absent.sorted())
    }

    /// The top-level values of `keys` in a JSON settings file (comments allowed); keys not set are left out.
    public static func values(_ keys: Set<String>, in text: String) throws -> [String: JSONValue] {
        let bytes = Array((text.isEmpty ? "{}" : text).utf8)
        var scanner = Scanner(bytes)
        var found: [String: JSONValue] = [:]
        for member in try scanner.topLevelObject().members where keys.contains(member.key) {
            guard let value = member.value(in: bytes) else { throw Unreadable(reason: "the value of \"\(member.key)\" isn't plain JSON") }
            found[member.key] = value
        }
        return found
    }

    static func json(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A member's value as it goes in the file: objects and arrays one entry a line, indented like the
    /// file's own members (`indent` is one level), keys in order so the same value always reads the same.
    static func render(_ value: JSONValue, indent: String, depth: Int = 1) throws -> String {
        let unit = indent.isEmpty ? "    " : indent
        let outer = String(repeating: unit, count: depth), inner = outer + unit
        switch value {
        case .object(let members) where !members.isEmpty:
            let lines = try members.keys.sorted().map { "\(inner)\(try json(.string($0))): \(try render(members[$0]!, indent: indent, depth: depth + 1))" }
            return "{\n" + lines.joined(separator: ",\n") + "\n\(outer)}"
        case .array(let items) where !items.isEmpty:
            let lines = try items.map { "\(inner)\(try render($0, indent: indent, depth: depth + 1))" }
            return "[\n" + lines.joined(separator: ",\n") + "\n\(outer)]"
        default:
            return try json(value)
        }
    }

    /// Takes a member out with its line, and the comma before it when it was the last one.
    static func removal(of index: Int, in object: Scanner.Object, bytes: [UInt8]) -> Range<Int> {
        let member = object.members[index]
        var start = member.keyStart
        while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") { start -= 1 }
        if start > 0, bytes[start - 1] == UInt8(ascii: "\n") { start -= 1 }
        var end = member.end
        if member.hasComma {
            return start..<end
        }
        // The last member: the previous one's comma goes too (strict JSON allows no trailing comma).
        if index > 0, object.members[index - 1].hasComma {
            start = object.members[index - 1].commaAt
        }
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return start..<end
    }

    /// A small, forgiving reader for one object's top-level members: it understands strings,
    /// nesting, // and /* */ comments and trailing commas, which is all it needs to find each key's
    /// value without parsing (or rewriting) the rest.
    struct Scanner {
        struct Member {
            let key: String
            let keyStart: Int
            let valueStart: Int
            let valueEnd: Int
            /// After the member and its comma, if any.
            let end: Int
            let hasComma: Bool
            let commaAt: Int

            func value(in bytes: [UInt8]) -> JSONValue? {
                let text = Scanner.withoutComments(Array(bytes[valueStart..<valueEnd]))
                return try? JSONDecoder().decode(JSONValue.self, from: Data(text))
            }
        }

        struct Object {
            let open: Int
            let close: Int
            let members: [Member]

            /// The indentation the members use (four spaces if there are none).
            func indent(in bytes: [UInt8]) -> String {
                guard let first = members.first else { return "    " }
                var start = first.keyStart
                while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") { start -= 1 }
                return String(decoding: bytes[start..<first.keyStart], as: UTF8.self)
            }
        }

        let bytes: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func topLevelObject() throws -> Object {
            skipSpaceAndComments()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { throw Unreadable(reason: "it doesn't start with {") }
            let open = i
            i += 1
            var members: [Member] = []
            while true {
                skipSpaceAndComments()
                guard i < bytes.count else { throw Unreadable(reason: "it ends too soon") }
                if bytes[i] == UInt8(ascii: "}") { return Object(open: open, close: i, members: members) }
                guard bytes[i] == UInt8(ascii: "\"") else { throw Unreadable(reason: "a key isn't in quotes") }
                let keyStart = i
                let key = try string()
                skipSpaceAndComments()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw Unreadable(reason: "\"\(key)\" has no value") }
                i += 1
                skipSpaceAndComments()
                let valueStart = i
                let valueEnd = try value()
                skipSpaceAndComments()
                guard i < bytes.count else { throw Unreadable(reason: "it ends too soon") }
                if bytes[i] == UInt8(ascii: ",") {
                    let comma = i
                    i += 1
                    members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd,
                                          end: i, hasComma: true, commaAt: comma))
                } else if bytes[i] == UInt8(ascii: "}") {
                    members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd,
                                          end: valueEnd, hasComma: false, commaAt: valueEnd))
                } else {
                    throw Unreadable(reason: "something unexpected follows \"\(key)\"")
                }
            }
        }

        /// Reads a quoted string, returning its text.
        mutating func string() throws -> String {
            let start = i
            i += 1
            while i < bytes.count, bytes[i] != UInt8(ascii: "\"") {
                i += bytes[i] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard i < bytes.count else { throw Unreadable(reason: "a string never ends") }
            i += 1
            guard let text = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<i])) else {
                throw Unreadable(reason: "a key has a broken escape")
            }
            return text
        }

        /// Skips one value (of any kind), returning where it ends (before any space or comment after it).
        mutating func value() throws -> Int {
            var depth = 0
            var end = i
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") {
                    _ = try string()
                    end = i
                    continue
                }
                if byte == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") || bytes[i + 1] == UInt8(ascii: "*") {
                    skipSpaceAndComments()
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    if depth == 0 { return end }
                    depth -= 1
                }
                if byte == UInt8(ascii: ","), depth == 0 { return end }
                i += 1
                if !Self.isSpace(byte) { end = i }
            }
            throw Unreadable(reason: "it ends too soon")
        }

        mutating func skipSpaceAndComments() {
            while i < bytes.count {
                if Self.isSpace(bytes[i]) {
                    i += 1
                } else if bytes[i] == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                    while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                } else if bytes[i] == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    i = min(i + 2, bytes.count)
                } else {
                    return
                }
            }
        }

        static func isSpace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
        }

        /// A value's text without comments or trailing commas, for parsing.
        static func withoutComments(_ bytes: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            var i = 0
            var inString = false
            while i < bytes.count {
                let byte = bytes[i]
                if inString {
                    out.append(byte)
                    if byte == UInt8(ascii: "\\"), i + 1 < bytes.count {
                        out.append(bytes[i + 1])
                        i += 2
                        continue
                    }
                    if byte == UInt8(ascii: "\"") { inString = false }
                    i += 1
                } else if byte == UInt8(ascii: "\"") {
                    inString = true
                    out.append(byte)
                    i += 1
                } else if byte == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
                    while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                } else if byte == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
                    i += 2
                    while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
                    i += 2
                } else {
                    if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}"),
                       let last = out.lastIndex(where: { !isSpace($0) }), out[last] == UInt8(ascii: ",") {
                        out.remove(at: last)
                    }
                    out.append(byte)
                    i += 1
                }
            }
            return out
        }
    }
}
