import Foundation

/// Builds partial patches so individual lines of a hunk can be staged, unstaged or discarded.
enum PatchBuilder {
    struct Unsupported: LocalizedError {
        let errorDescription: String?
    }

    /// File headers that make a partial patch unsafe: applying them in part would stage or
    /// unstage the whole rename / creation / deletion.
    static func supportsPartial(_ header: [String]) -> Bool {
        !header.contains { line in
            line.hasPrefix("rename from") || line.hasPrefix("rename to") || line.hasPrefix("copy from")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
        }
    }

    /// - Parameters:
    ///   - reverse: `false` when the patch is applied forward onto the index (stage).
    ///     `true` when it is applied with `git apply -R` (unstage from index, discard from worktree).
    /// - Returns: `nil` when no change line is selected.
    /// - Throws: `Unsupported` when a correct partial patch can't be expressed.
    static func patch(header: [String], hunk: DiffHunk, selected: Set<Int>, reverse: Bool) throws -> String? {
        let lines = hunk.lines
        var body: [String] = []
        var oldCount = 0, newCount = 0
        var lastEmitted = false
        var changed = false
        var skipAddition: String?   // the "+b" already synthesised for a kept last line
        let marker = "\\ No newline at end of file"

        func hasMarker(_ i: Int) -> Bool { i + 1 < lines.count && lines[i + 1].kind == .noNewline }
        /// Will any change line after `i` be emitted as a real change?
        func laterChange(after i: Int) -> Bool {
            lines[(i + 1)...].contains { $0.isChange && selected.contains($0.id) }
        }

        for (i, line) in lines.enumerated() {
            switch line.kind {
            case .context:
                body.append(" " + line.text)
                oldCount += 1; newCount += 1
                lastEmitted = true
            case .addition:
                if let skip = skipAddition, skip == line.text {
                    skipAddition = nil
                    lastEmitted = false
                    continue
                }
                if selected.contains(line.id) {
                    body.append("+" + line.text); newCount += 1
                    lastEmitted = true; changed = true
                } else if reverse {
                    if hasMarker(i) && laterChange(after: i) {
                        throw Unsupported(errorDescription: "This selection touches the last line of a file without a trailing newline. Use the whole hunk instead.")
                    }
                    body.append(" " + line.text); oldCount += 1; newCount += 1
                    lastEmitted = true
                } else {
                    lastEmitted = false
                }
            case .deletion:
                if selected.contains(line.id) {
                    body.append("-" + line.text); oldCount += 1
                    lastEmitted = true; changed = true
                } else if !reverse {
                    if hasMarker(i) && laterChange(after: i) {
                        // The old last line had no newline; new lines follow it, so it needs one.
                        body.append("-" + line.text)
                        body.append(marker)
                        body.append("+" + line.text)
                        oldCount += 1; newCount += 1
                        skipAddition = line.text
                        lastEmitted = false   // its marker was written already
                    } else {
                        body.append(" " + line.text); oldCount += 1; newCount += 1
                        lastEmitted = true
                    }
                } else {
                    lastEmitted = false
                }
            case .noNewline:
                if lastEmitted { body.append("\\" + line.text) }
                lastEmitted = false
            }
        }
        guard changed else { return nil }
        let range = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@"
        return (header + [range] + body).joined(separator: "\n") + "\n"
    }
}
