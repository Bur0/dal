import Foundation

struct ConflictChunk: Identifiable, Hashable {
    enum Content: Hashable {
        case text([String])
        case conflict(ours: [String], base: [String]?, theirs: [String], oursLabel: String, theirsLabel: String)
    }
    let id: Int
    let content: Content

    var isConflict: Bool {
        if case .conflict = content { return true }
        return false
    }
}

enum ConflictChoice: Hashable {
    case ours, theirs, oursThenTheirs, theirsThenOurs
}

enum ConflictParser {
    /// A marker is exactly seven characters, optionally followed by a space and a label.
    private static func isMarker(_ line: String, _ char: Character) -> Bool {
        let marker = String(repeating: char, count: 7)
        return line == marker || line.hasPrefix(marker + " ")
    }

    static func parse(_ text: String) -> [ConflictChunk] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [ConflictChunk] = []
        var buffer: [String] = []
        var raw: [String] = []          // lines of the conflict being read, verbatim
        var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = ""
        enum State { case text, ours, base, theirs }
        var state = State.text

        func flushText() {
            if !buffer.isEmpty {
                chunks.append(ConflictChunk(id: chunks.count, content: .text(buffer)))
                buffer = []
            }
        }

        for line in lines {
            switch state {
            case .text:
                if isMarker(line, "<") {
                    flushText()
                    oursLabel = String(line.dropFirst(7)).trimmed
                    ours = []; base = nil; theirs = []
                    raw = [line]
                    state = .ours
                } else {
                    buffer.append(line)
                }
            case .ours:
                raw.append(line)
                if isMarker(line, "|") { base = []; state = .base }
                else if line == "=======" { state = .theirs }
                else { ours.append(line) }
            case .base:
                raw.append(line)
                if line == "=======" { state = .theirs } else { base?.append(line) }
            case .theirs:
                raw.append(line)
                if isMarker(line, ">") {
                    let theirsLabel = String(line.dropFirst(7)).trimmed
                    chunks.append(ConflictChunk(id: chunks.count, content: .conflict(
                        ours: ours, base: base, theirs: theirs, oursLabel: oursLabel, theirsLabel: theirsLabel)))
                    raw = []
                    state = .text
                } else {
                    theirs.append(line)
                }
            }
        }
        // An unterminated conflict (e.g. a document that merely quotes "<<<<<<<") is kept as plain
        // text so resolving never drops lines.
        if state != .text { buffer.append(contentsOf: raw) }
        flushText()
        return chunks
    }

    /// Returns nil while any conflict is still unresolved.
    static func resolve(_ chunks: [ConflictChunk], choices: [Int: ConflictChoice]) -> String? {
        var out: [String] = []
        for chunk in chunks {
            switch chunk.content {
            case .text(let lines):
                out.append(contentsOf: lines)
            case .conflict(let ours, _, let theirs, _, _):
                guard let choice = choices[chunk.id] else { return nil }
                switch choice {
                case .ours: out.append(contentsOf: ours)
                case .theirs: out.append(contentsOf: theirs)
                case .oursThenTheirs: out.append(contentsOf: ours + theirs)
                case .theirsThenOurs: out.append(contentsOf: theirs + ours)
                }
            }
        }
        return out.joined(separator: "\n")
    }
}
