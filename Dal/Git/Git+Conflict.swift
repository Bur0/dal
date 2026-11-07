import Foundation

extension Git {
    /// The text to resolve a conflicted file from. When the file on disk is still exactly what
    /// git wrote, the conflict is re-created from the index stages with the common ancestor
    /// included (zdiff3), so the merge tool can show the base. Anything edited by hand, or any
    /// difference at all, keeps the file on disk as the source.
    func conflictSource(path: String, working: String) async -> String {
        let chunks = ConflictParser.parse(working)
        guard let first = chunks.first(where: \.isConflict),
              case .conflict(_, let base, _, let oursLabel, let theirsLabel) = first.content,
              base == nil else { return working }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("dal-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            var files: [String] = []
            for stage in 1...3 {
                let blob = try await run(["cat-file", "blob", ":\(stage):\(path)"])
                let file = temp.appendingPathComponent("\(stage)")
                try blob.write(to: file)
                files.append(file.path)
            }
            let labels = ["-L", oursLabel, "-L", "base", "-L", theirsLabel]
            // Exit status is the number of conflicts; only a negative (signal/error) is a failure.
            let codes = Set<Int32>(0...127)
            let plain = try await string(["merge-file", "-p"] + labels + [files[1], files[0], files[2]], allowExit: codes)
            guard plain == working else { return working }
            let withBase = try await string(["merge-file", "-p", "--zdiff3"] + labels + [files[1], files[0], files[2]],
                                            allowExit: codes)
            // Same three versions, same merge; with the base git also stops gluing neighbouring
            // conflicts together, so there may be more (smaller) ones than in the file on disk.
            return ConflictParser.parse(withBase).contains(where: \.isConflict) ? withBase : working
        } catch {
            return working
        }
    }
}
