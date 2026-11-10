import Foundation

/// A JSON object kept as its top-level members in file order, each value as its original text.
/// Lets Switcher take a few keys out of an app's settings file and put others in while leaving
/// every other byte of every other value exactly as the app wrote it.
public struct OrderedJSON: Equatable {
    public struct Member: Equatable {
        public var key: String
        /// The value's JSON text, as found.
        public var raw: String

        public init(key: String, raw: String) {
            self.key = key
            self.raw = raw
        }
    }

    public var members: [Member] = []

    public init() {}

    public init(text: String) throws {
        var p = Parser(Array(text.utf8))
        members = try p.object().map(\.member)
    }

    /// `text` with every member named in `removing` taken out and `adding` appended, every other
    /// byte (other members, their spacing, the file's indentation and final newline) left as it was.
    public static func edit(_ text: String, removing: [String], adding: [Member]) throws -> String {
        var bytes = Array(text.utf8)
        func spans() throws -> [Parser.Span] {
            var p = Parser(bytes)
            return try p.object()
        }
        let indent = indentation(of: text)
        while let doomed = try spans().enumerated().first(where: { removing.contains($0.element.member.key) }) {
            let all = try spans()
            let n = doomed.offset, m = doomed.element
            let range: Range<Int>
            if n + 1 < all.count {
                range = m.leadStart..<all[n + 1].leadStart // its own lead, it, its comma; the next keeps its lead
            } else if n > 0 {
                range = all[n - 1].valueEnd..<m.valueEnd // the last one: the comma before it, through its value
            } else {
                // The only member: leave an empty object as `{}` with what followed the brace.
                let open = bytes[..<m.keyStart].lastIndex(of: UInt8(ascii: "{"))!
                var close = m.valueEnd
                while close < bytes.count, bytes[close] != UInt8(ascii: "}") { close += 1 }
                range = (open + 1)..<close
            }
            bytes.replaceSubrange(range, with: [])
        }
        for member in adding {
            let entry = Array("\(indent)\(quote(member.key)): \(member.raw)".utf8)
            if let last = try spans().last {
                bytes.insert(contentsOf: Array(",\n".utf8) + entry, at: last.valueEnd)
            } else {
                let open = bytes.firstIndex(of: UInt8(ascii: "{"))!
                let close = bytes.lastIndex(of: UInt8(ascii: "}"))!
                bytes.replaceSubrange((open + 1)..<close, with: Array("\n".utf8) + entry + Array("\n".utf8))
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public init(contentsOf url: URL) throws {
        try self.init(text: String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    public subscript(key: String) -> String? {
        get { members.first { $0.key == key }?.raw }
        set {
            if let i = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[i].raw = newValue } else { members.remove(at: i) }
            } else if let newValue {
                members.append(Member(key: key, raw: newValue))
            }
        }
    }

    public var keys: [String] { members.map(\.key) }

    /// The value of `key` decoded, when it is a string.
    public func string(_ key: String) -> String? {
        guard let raw = self[key], let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
    }

    /// The object as text, one member per line indented by `indent`.
    public func text(indent: String, trailingNewline: Bool = false) -> String {
        if members.isEmpty { return trailingNewline ? "{}\n" : "{}" }
        let body = members.map { "\(indent)\(Self.quote($0.key)): \($0.raw)" }.joined(separator: ",\n")
        return "{\n\(body)\n}" + (trailingNewline ? "\n" : "")
    }

    public static func quote(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Guess the indentation a file uses for its members (tab or spaces).
    public static func indentation(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let lead = line.prefix { $0 == " " || $0 == "\t" }
            if !lead.isEmpty { return String(lead) }
        }
        return "  "
    }

    struct Parser {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        mutating func ws() {
            while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        }

        func fail(_ what: String) -> SwitcherError { .message("malformed JSON (\(what) at byte \(i))") }

        struct Span {
            var member: Member
            /// Just after the `{` or `,` before it: where its leading whitespace starts.
            var leadStart: Int
            var keyStart: Int
            var valueEnd: Int
        }

        mutating func object() throws -> [Span] {
            ws()
            guard i < b.count, b[i] == UInt8(ascii: "{") else { throw fail("expected an object") }
            i += 1
            var out: [Span] = []
            var leadStart = i
            ws()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return out }
            while true {
                ws()
                let keyStart = i
                try skipString()
                let keyText = String(decoding: b[keyStart..<i], as: UTF8.self)
                guard let key = (try? JSONSerialization.jsonObject(with: Data(keyText.utf8), options: .fragmentsAllowed)) as? String else {
                    throw fail("bad key")
                }
                ws()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                ws()
                let valueStart = i
                try skipValue()
                out.append(Span(member: Member(key: key, raw: String(decoding: b[valueStart..<i], as: UTF8.self)), leadStart: leadStart, keyStart: keyStart, valueEnd: i))
                ws()
                guard i < b.count else { throw fail("unterminated object") }
                if b[i] == UInt8(ascii: ",") { i += 1; leadStart = i; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; break }
                throw fail("expected ',' or '}'")
            }
            ws()
            if i != b.count { throw fail("trailing data") }
            return out
        }

        mutating func skipString() throws {
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a string") }
            i += 1
            while i < b.count {
                if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                if b[i] == UInt8(ascii: "\"") { i += 1; return }
                i += 1
            }
            throw fail("unterminated string")
        }

        mutating func skipValue() throws {
            guard i < b.count else { throw fail("missing value") }
            switch b[i] {
            case UInt8(ascii: "\""):
                try skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while i < b.count {
                    switch b[i] {
                    case UInt8(ascii: "\""):
                        try skipString()
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 { i += 1; return }
                    default:
                        break
                    }
                    i += 1
                }
                throw fail("unterminated value")
            default:
                let start = i
                while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                if i == start { throw fail("missing value") }
            }
        }
    }
}
