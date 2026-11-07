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
    static func parse(_ text: String) -> [ConflictChunk] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [ConflictChunk] = []
        var buffer: [String] = []
        var ours: [String] = [], base: [String]? = nil, theirs: [String] = []
        var oursLabel = "", theirsLabel = ""
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
                if line.hasPrefix("<<<<<<<") {
                    flushText()
                    oursLabel = String(line.dropFirst(7)).trimmed
                    ours = []; base = nil; theirs = []
                    state = .ours
                } else {
                    buffer.append(line)
                }
            case .ours:
                if line.hasPrefix("|||||||") { base = []; state = .base }
                else if line.hasPrefix("=======") { state = .theirs }
                else { ours.append(line) }
            case .base:
                if line.hasPrefix("=======") { state = .theirs } else { base?.append(line) }
            case .theirs:
                if line.hasPrefix(">>>>>>>") {
                    theirsLabel = String(line.dropFirst(7)).trimmed
                    chunks.append(ConflictChunk(id: chunks.count, content: .conflict(
                        ours: ours, base: base, theirs: theirs, oursLabel: oursLabel, theirsLabel: theirsLabel)))
                    state = .text
                } else {
                    theirs.append(line)
                }
            }
        }
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
