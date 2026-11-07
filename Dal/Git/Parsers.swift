import Foundation

/// Pure parsers for git plumbing output. Kept free of I/O so they can be unit-tested.
enum Parse {
    static let fieldSep: Character = "\u{1f}"
    static let recordSep: Character = "\u{1e}"

    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%s%x1f%b%x1e"

    static func log(_ text: String) -> [Commit] {
        var commits: [Commit] = []
        for record in text.split(separator: recordSep, omittingEmptySubsequences: true) {
            let rec = record.drop(while: { $0 == "\n" })
            if rec.isEmpty { continue }
            let f = rec.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 10 else { continue }
            commits.append(Commit(
                sha: f[0],
                parents: f[1].split(separator: " ").map(String.init),
                authorName: f[2],
                authorEmail: f[3],
                authorDate: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                committerName: f[5],
                committerEmail: f[6],
                commitDate: Date(timeIntervalSince1970: TimeInterval(f[7]) ?? 0),
                subject: f[8],
                body: f[9...].joined(separator: "\u{1f}").trimmed
            ))
        }
        return commits
    }

    static let refFormat = "%(refname)%1f%(objectname)%1f%(*objectname)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(HEAD)%1f%(upstream:remotename)%1f%(upstream:remoteref)"

    static func refs(_ text: String) -> [Ref] {
        var result: [Ref] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            let full = f[0]
            let kind: RefKind
            let name: String
            if full.hasPrefix("refs/heads/") {
                kind = .localBranch; name = String(full.dropFirst("refs/heads/".count))
            } else if full.hasPrefix("refs/remotes/") {
                kind = .remoteBranch; name = String(full.dropFirst("refs/remotes/".count))
                if name.hasSuffix("/HEAD") { continue }
            } else if full.hasPrefix("refs/tags/") {
                kind = .tag; name = String(full.dropFirst("refs/tags/".count))
            } else { continue }
            let target = f[2].isEmpty ? f[1] : f[2]
            var ref = Ref(fullName: full, name: name, kind: kind, target: target)
            ref.upstream = f[3].isEmpty ? nil : f[3]
            let t = track(f[4])
            ref.ahead = t.ahead; ref.behind = t.behind; ref.upstreamGone = t.gone
            ref.isHead = f[5] == "*"
            if f.count >= 8, !f[6].isEmpty {
                ref.upstreamRemote = f[6]
                ref.upstreamBranch = f[7].hasPrefix("refs/heads/") ? String(f[7].dropFirst("refs/heads/".count)) : nil
            }
            result.append(ref)
        }
        return result
    }

    static func track(_ s: String) -> (ahead: Int, behind: Int, gone: Bool) {
        if s == "gone" { return (0, 0, true) }
        var ahead = 0, behind = 0
        for part in s.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let n = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
        }
        return (ahead, behind, false)
    }

    /// `git status --porcelain=v1 -z`
    static func status(_ text: String) -> WorkingStatus {
        var status = WorkingStatus()
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]
        var i = 0
        while i < tokens.count {
            let entry = tokens[i]
            i += 1
            guard entry.count > 3 else { continue }
            let x = entry[entry.startIndex]
            let y = entry[entry.index(after: entry.startIndex)]
            let path = String(entry.dropFirst(3))
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < tokens.count { oldPath = tokens[i]; i += 1 }
            }
            let code = String([x, y])
            if conflictCodes.contains(code) {
                status.conflicted.append(FileChange(path: path, kind: .conflicted, conflictCode: code))
                continue
            }
            if code == "??" {
                status.unstaged.append(FileChange(path: path, kind: .untracked))
                continue
            }
            if code == "!!" { continue }
            if x != " " {
                status.staged.append(FileChange(path: path, oldPath: (x == "R" || x == "C") ? oldPath : nil,
                                                kind: ChangeKind(code: x)))
            }
            if y != " " {
                status.unstaged.append(FileChange(path: path, oldPath: (y == "R" || y == "C") ? oldPath : nil,
                                                  kind: ChangeKind(code: y)))
            }
        }
        status.staged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        status.unstaged.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    /// `git diff --name-status -z`
    static func nameStatus(_ text: String) -> [FileChange] {
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let first = code.first else { continue }
            if first == "R" || first == "C" {
                guard i + 1 < tokens.count else { break }
                result.append(FileChange(path: tokens[i + 1], oldPath: tokens[i], kind: ChangeKind(code: first)))
                i += 2
            } else {
                guard i < tokens.count else { break }
                result.append(FileChange(path: tokens[i], kind: ChangeKind(code: first)))
                i += 1
            }
        }
        return result
    }

    static let stashFormat = "%H%x1f%ct%x1f%gs%x1e"

    static func stashes(_ text: String) -> [Stash] {
        var result: [Stash] = []
        for (i, record) in text.split(separator: recordSep).enumerated() {
            let rec = record.drop(while: { $0 == "\n" })
            let f = rec.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, !f[0].isEmpty else { continue }
            result.append(Stash(index: i, sha: f[0],
                                message: stashMessage(f[2]),
                                date: Date(timeIntervalSince1970: TimeInterval(f[1]) ?? 0)))
        }
        return result
    }

    /// "On main: idea" → "idea"; "WIP on main: 1a2b3c msg" → "WIP: msg"
    static func stashMessage(_ raw: String) -> String {
        let text = raw.trimmed
        if text.hasPrefix("On "), let colon = text.range(of: ": ") {
            return String(text[colon.upperBound...])
        }
        if text.hasPrefix("WIP on "), let colon = text.range(of: ": ") {
            let rest = text[colon.upperBound...]
            let message = rest.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? String(rest)
            return "WIP: " + message
        }
        return text
    }

    static func worktrees(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        var current: Worktree?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if let c = current { result.append(c) }
                current = Worktree(path: String(line.dropFirst("worktree ".count)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                current?.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" {
                current?.isBare = true
            }
        }
        if let c = current { result.append(c) }
        if !result.isEmpty { result[0].isMain = true }
        return result
    }

    static func diff(_ text: String) -> FileDiff {
        var diff = FileDiff()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var hunkLines: [DiffLine] = []
        var hunkHeader: (String, Int, Int, Int, Int)?
        var oldNo = 0, newNo = 0
        var lineID = 0
        var hunkID = 0

        func flush() {
            guard let h = hunkHeader else { return }
            diff.hunks.append(DiffHunk(id: hunkID, header: h.0, oldStart: h.1, oldCount: h.2,
                                       newStart: h.3, newCount: h.4, lines: hunkLines))
            hunkID += 1
            hunkLines = []
            hunkHeader = nil
        }

        for line in lines {
            if line.hasPrefix("@@") {
                flush()
                if let h = hunkRange(line) {
                    hunkHeader = (line, h.0, h.1, h.2, h.3)
                    oldNo = h.0
                    newNo = h.2
                }
                continue
            }
            guard hunkHeader != nil else {
                if line.hasPrefix("Binary files") || line.hasPrefix("GIT binary patch") { diff.isBinary = true }
                if !diff.hunks.isEmpty { continue }
                diff.header.append(line)
                continue
            }
            if line.hasPrefix("diff --git") {
                // A second file in the same output; we only render one file per view.
                flush()
                break
            }
            let marker = line.first
            let body = line.isEmpty ? "" : String(line.dropFirst())
            switch marker {
            case "+":
                hunkLines.append(DiffLine(id: lineID, kind: .addition, text: body, oldNumber: nil, newNumber: newNo))
                newNo += 1
            case "-":
                hunkLines.append(DiffLine(id: lineID, kind: .deletion, text: body, oldNumber: oldNo, newNumber: nil))
                oldNo += 1
            case "\\":
                hunkLines.append(DiffLine(id: lineID, kind: .noNewline, text: body, oldNumber: nil, newNumber: nil))
            default:
                hunkLines.append(DiffLine(id: lineID, kind: .context, text: body, oldNumber: oldNo, newNumber: newNo))
                oldNo += 1; newNo += 1
            }
            lineID += 1
        }
        flush()
        return diff
    }

    /// "@@ -12,7 +12,9 @@ func" -> (12, 7, 12, 9)
    static func hunkRange(_ header: String) -> (Int, Int, Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ s: Substring) -> (Int, Int) {
            let nums = s.dropFirst().split(separator: ",")
            let start = Int(nums.first ?? "0") ?? 0
            let count = nums.count > 1 ? Int(nums[1]) ?? 0 : 1
            return (start, count)
        }
        let o = range(parts[1]), n = range(parts[2])
        return (o.0, o.1, n.0, n.1)
    }

    /// Groups refs into graph badges keyed by commit sha.
    static func badges(_ refs: [Ref]) -> [String: [RefBadge]] {
        var bySha: [String: [RefBadge]] = [:]
        let grouped = Dictionary(grouping: refs, by: \.target)
        for (sha, list) in grouped {
            var badges: [RefBadge] = []
            let locals = list.filter { $0.kind == .localBranch }
            var remotes = list.filter { $0.kind == .remoteBranch }
            for local in locals {
                var badge = RefBadge(id: local.fullName, name: local.name, local: local, isHead: local.isHead)
                let matching = remotes.filter { $0.branchName == local.name }
                badge.remotes = matching
                remotes.removeAll { r in matching.contains(r) }
                badges.append(badge)
            }
            for remote in remotes {
                badges.append(RefBadge(id: remote.fullName, name: remote.name, remotes: [remote]))
            }
            for tag in list.filter({ $0.kind == .tag }) {
                badges.append(RefBadge(id: tag.fullName, name: tag.name, tag: tag))
            }
            badges.sort { a, b in
                if a.isHead != b.isHead { return a.isHead }
                let ka = a.primary?.kind ?? .tag, kb = b.primary?.kind ?? .tag
                if ka != kb { return ka < kb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            bySha[sha] = badges
        }
        return bySha
    }
}
