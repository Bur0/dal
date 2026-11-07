import Foundation

/// Builds partial patches so individual lines of a hunk can be staged, unstaged or discarded.
enum PatchBuilder {
    /// - Parameters:
    ///   - reverse: `false` when the patch is applied forward onto the index (stage).
    ///     `true` when it is applied with `git apply -R` (unstage from index, discard from worktree).
    /// - Returns: `nil` when no change line is selected.
    static func patch(header: [String], hunk: DiffHunk, selected: Set<Int>, reverse: Bool) -> String? {
        var body: [String] = []
        var oldCount = 0, newCount = 0
        var lastEmitted = false
        var changed = false

        for line in hunk.lines {
            switch line.kind {
            case .context:
                body.append(" " + line.text)
                oldCount += 1; newCount += 1
                lastEmitted = true
            case .addition:
                if selected.contains(line.id) {
                    body.append("+" + line.text); newCount += 1
                    lastEmitted = true; changed = true
                } else if reverse {
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
                    body.append(" " + line.text); oldCount += 1; newCount += 1
                    lastEmitted = true
                } else {
                    lastEmitted = false
                }
            case .noNewline:
                if lastEmitted { body.append("\\" + line.text) }
            }
        }
        guard changed else { return nil }
        let range = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@"
        return (header + [range] + body).joined(separator: "\n") + "\n"
    }
}
