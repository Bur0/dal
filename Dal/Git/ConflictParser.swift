import Foundation

struct ConflictChunk: Identifiable, Hashable {
    enum Content: Hashable {
        case text([String])
        case conflict(ours: [String], base: [String]?, theirs: [String], oursLabel: String, theirsLabel: String)
    }
    let id: Int
    let content: Content
    /// The conflict exactly as it appeared, markers included (used when editing the output by hand).
    var raw: [String] = []

    var isConflict: Bool {
        if case .conflict = content { return true }
        return false
    }
}

enum ConflictChoice: Hashable {
    case ours, theirs, oursThenTheirs, theirsThenOurs
}

/// What the user kept of one conflict: any lines of either side, in file order per side.
/// The side picked first goes first in the output (like GitKraken), and can be swapped.
struct ConflictPick: Hashable {
    var ours: Set<Int> = []
    var theirs: Set<Int> = []
    var theirsFirst = false
    /// "Neither side": the conflict resolves to nothing.
    var neither = false

    var isResolved: Bool { neither || !ours.isEmpty || !theirs.isEmpty }

    init(ours: Set<Int> = [], theirs: Set<Int> = [], theirsFirst: Bool = false, neither: Bool = false) {
        self.ours = ours; self.theirs = theirs; self.theirsFirst = theirsFirst; self.neither = neither
    }

    init(_ choice: ConflictChoice, oursCount: Int, theirsCount: Int) {
        let all = { (n: Int) in Set(0..<n) }
        switch choice {
        case .ours: self.init(ours: all(oursCount), neither: oursCount == 0)
        case .theirs: self.init(theirs: all(theirsCount), neither: theirsCount == 0)
        case .oursThenTheirs: self.init(ours: all(oursCount), theirs: all(theirsCount), neither: oursCount + theirsCount == 0)
        case .theirsThenOurs: self.init(ours: all(oursCount), theirs: all(theirsCount), theirsFirst: true,
                                        neither: oursCount + theirsCount == 0)
        }
    }

    /// The kept lines, in output order, tagged with the side they came from.
    func lines(ours oursLines: [String], theirs theirsLines: [String]) -> [(line: String, fromOurs: Bool)] {
        if neither { return [] }
        let a = ours.sorted().filter { $0 < oursLines.count }.map { (oursLines[$0], true) }
        let b = theirs.sorted().filter { $0 < theirsLines.count }.map { (theirsLines[$0], false) }
        return theirsFirst ? b + a : a + b
    }
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
                        ours: ours, base: base, theirs: theirs, oursLabel: oursLabel, theirsLabel: theirsLabel), raw: raw))
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
        var picks: [Int: ConflictPick] = [:]
        for chunk in chunks {
            if case .conflict(let ours, _, let theirs, _, _) = chunk.content, let choice = choices[chunk.id] {
                picks[chunk.id] = ConflictPick(choice, oursCount: ours.count, theirsCount: theirs.count)
            }
        }
        return resolve(chunks, picks: picks)
    }

    /// Returns nil while any conflict is still unresolved.
    static func resolve(_ chunks: [ConflictChunk], picks: [Int: ConflictPick]) -> String? {
        guard chunks.allSatisfy({ !$0.isConflict || picks[$0.id]?.isResolved == true }) else { return nil }
        return render(chunks, picks: picks)
    }

    /// The file with every decided conflict applied; undecided ones keep their original markers.
    static func render(_ chunks: [ConflictChunk], picks: [Int: ConflictPick]) -> String {
        var out: [String] = []
        for chunk in chunks {
            switch chunk.content {
            case .text(let lines):
                out.append(contentsOf: lines)
            case .conflict(let ours, _, let theirs, _, _):
                if let pick = picks[chunk.id], pick.isResolved {
                    out.append(contentsOf: pick.lines(ours: ours, theirs: theirs).map(\.line))
                } else {
                    out.append(contentsOf: chunk.raw)
                }
            }
        }
        return out.joined(separator: "\n")
    }

    /// True when text still has a complete conflict block.
    static func hasMarkers(_ text: String) -> Bool {
        parse(text).contains(where: \.isConflict)
    }
}
