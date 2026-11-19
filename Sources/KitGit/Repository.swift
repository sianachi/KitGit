import Foundation

struct Patch {
    struct Line: Identifiable {
        let id: Int
        let text: String
        var selectable: Bool { text.hasPrefix("+") || text.hasPrefix("-") }
    }

    struct Hunk: Identifiable {
        let id: Int
        let header: String
        let lines: [Line]
    }

    let raw: String
    let header: [String]
    let hunks: [Hunk]

    init(_ raw: String) {
        self.raw = raw
        let lines = raw.droppingFinalNewline.components(separatedBy: "\n")
        var starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
        header = Array(lines.prefix(starts.first ?? lines.count))
        starts.append(lines.count)
        hunks = zip(starts, starts.dropFirst()).map { start, end in
            Hunk(id: start, header: lines[start], lines: ((start + 1)..<end).map { Line(id: $0, text: lines[$0]) })
        }
    }

    var isNewFile: Bool { header.contains("--- /dev/null") }

    var supportsSelection: Bool {
        // shortcut: stage whole files with missing final newlines, until partial patches handle EOF markers.
        !hunks.isEmpty && (isNewFile || header.contains(where: { $0.hasPrefix("--- a/") || $0.hasPrefix("--- \"a/") }))
            && header.contains(where: { $0.hasPrefix("+++ b/") || $0.hasPrefix("+++ \"b/") })
            && hunks.allSatisfy { !$0.lines.contains(where: { $0.text.hasPrefix("\\") }) }
    }

    func selected(_ ids: Set<Int>) throws -> String {
        guard supportsSelection else {
            throw GitFailure(message: "Stage this file as a whole. Its patch does not support line selection.")
        }
        var shift = 0
        var result = header.filter {
            (isNewFile && $0.hasPrefix("new file mode ")) || $0.hasPrefix("diff --git ") || $0.hasPrefix("--- ") || $0.hasPrefix("+++ ")
        }
        var included = false
        for hunk in hunks where hunk.lines.contains(where: { $0.selectable && ids.contains($0.id) }) {
            guard let range = hunk.header.split(separator: " ").dropFirst().first,
                  let oldStart = Int(range.dropFirst().split(separator: ",")[0]) else {
                throw GitFailure(message: "Git returned an unreadable patch.")
            }
            let lines = hunk.lines.compactMap { line -> String? in
                if ids.contains(line.id) || !line.selectable { return line.text }
                return line.text.hasPrefix("-") ? " " + line.text.dropFirst() : nil
            }
            let oldCount = lines.filter { !$0.hasPrefix("+") }.count
            let newCount = lines.filter { !$0.hasPrefix("-") }.count
            let offset = (oldCount == 0 ? 1 : 0) - (newCount == 0 ? 1 : 0)
            result.append("@@ -\(oldStart),\(oldCount) +\(oldStart + shift + offset),\(newCount) @@")
            result.append(contentsOf: lines)
            shift += newCount - oldCount
            included = true
        }
        guard included else { throw GitFailure(message: "Select at least one changed line.") }
        return result.joined(separator: "\n") + "\n"
    }
}

struct Conflict {
    let path: String
    let index: [String]
    let original: Data?
    let ours: String?
    let theirs: String?
    var result: String
    let editable: Bool

    struct Block: Identifiable {
        let id: Int
        let end: Int
        let ours: [String]
        let theirs: [String]
    }

    static func isMarker(_ line: String) -> Bool {
        guard let token = line.split(separator: " ").first, token.count >= 3,
              let symbol = token.first, "<=>|".contains(symbol) else { return false }
        return token.allSatisfy { $0 == symbol }
    }

    static func blocks(in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [Block] = []
        var start = 0
        while start < lines.count {
            guard let marker = lines[start].split(separator: " ").first,
                  marker.count >= 3, marker.allSatisfy({ $0 == "<" }),
                  let separator = lines.indices.dropFirst(start + 1).first(where: {
                      lines[$0] == String(repeating: "=", count: marker.count)
                  }),
                  let end = lines.indices.dropFirst(separator + 1).first(where: {
                      lines[$0].hasPrefix(String(repeating: ">", count: marker.count) + " ")
                  }) else {
                start += 1
                continue
            }
            let base = ((start + 1)..<separator).first {
                lines[$0].hasPrefix(String(repeating: "|", count: marker.count) + " ")
            } ?? separator
            blocks.append(Block(id: start, end: end, ours: Array(lines[(start + 1)..<base]),
                                theirs: Array(lines[(separator + 1)..<end])))
            start = end + 1
        }
        return blocks
    }

    mutating func accept(_ block: Block, ours: Bool) {
        var lines = result.components(separatedBy: "\n")
        lines.replaceSubrange(block.id...block.end, with: ours ? block.ours : block.theirs)
        result = lines.joined(separator: "\n")
    }
}

struct Branch: Identifiable, Codable {
    let id: String
    let name: String
    let remote: Bool
}

struct Commit: Identifiable, Codable {
    let id: String
    let parents: [String]
    let refs: String
    let subject: String
    let author: String
    let date: String
}

struct GraphRow: Identifiable, Codable {
    struct Edge: Codable {
        let from: Int
        let to: Int
        let color: Int
    }

    let commit: Commit
    let lane: Int
    let color: Int
    let above: [Edge]
    let below: [Edge]
    var id: String { commit.id }

    static func layout(_ commits: [Commit]) -> (rows: [GraphRow], width: Int) {
        struct Lane {
            let hash: String
            let color: Int
        }
        var lanes: [Lane] = []
        var nextColor = 0
        var width = 1
        var rows: [GraphRow] = []
        for commit in commits {
            let existing = lanes.firstIndex { $0.hash == commit.id }
            let slot = existing ?? lanes.count
            let color = existing.map { lanes[$0].color } ?? nextColor
            if existing == nil { nextColor += 1 }
            let above = lanes.enumerated().map { Edge(from: $0.offset, to: $0.offset, color: $0.element.color) }
            let previous = lanes
            if existing != nil { lanes.remove(at: slot) }
            for (index, parent) in commit.parents.enumerated() where !lanes.contains(where: { $0.hash == parent }) {
                lanes.insert(Lane(hash: parent, color: index == 0 ? color : nextColor),
                             at: min(slot + index, lanes.count))
                if index > 0 { nextColor += 1 }
            }
            var below = previous.enumerated().compactMap { offset, lane -> Edge? in
                guard let target = lanes.firstIndex(where: { $0.hash == lane.hash }) else { return nil }
                return Edge(from: offset, to: target, color: lane.color)
            }
            below += commit.parents.compactMap { parent in
                lanes.firstIndex(where: { $0.hash == parent }).map {
                    Edge(from: slot, to: $0, color: lanes[$0].color)
                }
            }
            width = max(width, lanes.count, slot + 1, previous.count)
            rows.append(GraphRow(commit: commit, lane: slot, color: color, above: above, below: below))
        }
        return (rows, width)
    }
}

struct Repository {
    let root: URL
    let branch: String
    let branches: [Branch]
    let worktrees: [Worktree]
    let tags: [String]
    let stashes: [Stash]
    let graph: (rows: [GraphRow], width: Int)
    let staged: [String]
    let unstaged: [String]
    let conflicts: [String]
    let merging: Bool
    let replayOperation: String?
    var operationInProgress: Bool { rebasing || merging || replayOperation != nil }
    let remotes: [String]
    let gitHubRemotes: [GitHubRemote]
    let rebasing: Bool
    let savedChanges: Bool
    let dirty: Bool
    let canLoadMore: Bool

    init(git: Git, limit: Int) throws {
        root = git.root
        worktrees = try git.worktrees()
        stashes = try git.stashes()
        tags = try git.run(["for-each-ref", "--format=%(refname:strip=2)", "refs/tags"])
            .split(separator: "\n").map(String.init)
        branch = try git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], accepting: [0, 1]).droppingFinalNewline
        let refs = try git.run(["for-each-ref", "--format=%(refname)%09%(symref)", "refs/heads", "refs/remotes"])
        branches = refs.split(separator: "\n").compactMap {
            let parts = $0.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].isEmpty else { return nil }
            let ref = String(parts[0])
            let remote = ref.hasPrefix("refs/remotes/")
            return Branch(id: ref, name: String(ref.dropFirst(remote ? 13 : 11)), remote: remote)
        }
        let head = try git.run(["rev-parse", "-q", "--verify", "HEAD"], accepting: [0, 1])
        let commits = try git.commits(["--branches", "--remotes", "--tags", "--topo-order",
                                       "-n", String(limit + 1)] + (head.isEmpty ? [] : ["HEAD"]))
        graph = GraphRow.layout(Array(commits.prefix(limit)))
        canLoadMore = commits.count > limit
        conflicts = try Array(Set(git.paths(["diff", "--name-only", "--diff-filter=U", "-z"]))).sorted()
        let conflicted = Set(conflicts)
        staged = try git.paths(["diff", "--cached", "--name-only", "--no-renames", "-z"]).filter { !conflicted.contains($0) }
        unstaged = try (git.paths(["diff", "--name-only", "--no-renames", "-z"])
            + git.paths(["ls-files", "--others", "--exclude-standard", "-z"])).filter { !conflicted.contains($0) }.sorted()
        let manager = FileManager.default
        merging = try manager.fileExists(atPath: git.gitPath("MERGE_HEAD").path)
        if try manager.fileExists(atPath: git.gitPath("CHERRY_PICK_HEAD").path) {
            replayOperation = "cherry-pick"
        } else if try manager.fileExists(atPath: git.gitPath("REVERT_HEAD").path) {
            replayOperation = "revert"
        } else {
            replayOperation = nil
        }
        remotes = try git.run(["remote"]).split(separator: "\n").map(String.init)
        gitHubRemotes = remotes.compactMap { name in
            guard let url = try? git.run(["remote", "get-url", "--", name]) else { return nil }
            return GitHubRemote(name: name, address: url.droppingFinalNewline)
        }
        rebasing = try git.rebaseActive()
        savedChanges = try git.pendingStash() != nil
        dirty = try !git.run(["status", "--porcelain", "-z"]).isEmpty
    }
}
