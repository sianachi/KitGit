import Foundation
#if os(Windows)
import ucrt
#else
import Glibc
#endif

@main
struct DesktopBridge {
    struct Request: Decodable {
        let action: String
        let root: String
        var args: [String] = []
        var text: String?
        var ids: [Int]?
        var plan: RebasePlan?
        var conflict: ConflictVersion?
        var request: PullRequest?
    }

    struct ConflictVersion: Codable {
        let index: [String]
        let original: Data?
    }

    static func main() {
        do {
            let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
            let data = try handle(request)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            exit(1)
        }
    }

    static func handle(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        let args = request.args
        let url = URL(fileURLWithPath: request.root, isDirectory: true)
        if request.action == "create" {
            let manager = FileManager.default
            if manager.fileExists(atPath: url.path),
               try !manager.contentsOfDirectory(atPath: url.path).isEmpty {
                throw GitFailure(message: "Choose a new or empty directory.")
            }
            let git = Git(root: url.deletingLastPathComponent())
            if let source = args.first {
                try git.run(["-c", "protocol.ext.allow=never", "clone", "--", source, url.path])
            } else {
                try git.run(["init", "--", url.path])
            }
            return try encoder.encode(url.path)
        }
        let git = try Git.open(url)
        func arg(_ index: Int = 0) throws -> String {
            guard args.indices.contains(index) else { throw GitFailure(message: "Missing action argument.") }
            return args[index]
        }
        func stash() throws -> Stash {
            let hash = try arg()
            guard let stash = try git.stashes().first(where: { $0.hash == hash }) else {
                throw GitFailure(message: "This stash changed. Refresh the repository.")
            }
            return stash
        }

        switch request.action {
        case "status":
            let limit = args.first.flatMap(Int.init) ?? 300
            guard (1...100_000).contains(limit) else { throw GitFailure(message: "Invalid history limit.") }
            return try encoder.encode(Status(Repository(git: git, limit: limit)))
        case "git":
            return try encoder.encode(git.run(args, input: request.text))
        case "files":
            return try encoder.encode(Set(git.paths(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])).sorted())
        case "commitFiles":
            return try encoder.encode(git.paths(["show", "--format=", "--first-parent", "--diff-merges=first-parent",
                                                 "--no-renames", "--name-only", "-z", arg(), "--"]))
        case "search":
            return try encoder.encode(git.searchCommits(arg()))
        case "history":
            return try encoder.encode(git.commits(["--follow", "-n", "100", arg(1), "--", arg()]))
        case "file":
            let path = try arg()
            let revision = try arg(1)
            let inspection: FileInspection
            if ["staged", "unstaged"].contains(revision) {
                inspection = try git.inspectFile(path, staged: revision == "staged")
            } else {
                let commits = try git.commits(["-n", "1", revision, "--"])
                guard let commit = commits.first else { throw GitFailure(message: "Commit is unavailable.") }
                inspection = try git.inspectFile(path, at: commit)
            }
            return try encoder.encode(Inspection(inspection, path: path))
        case "stage":
            try git.stageFile(arg(), unstage: args.dropFirst().first == "unstage")
        case "stageLines":
            try git.stageLines(arg(), originalDiff: request.text ?? "", lines: Set(request.ids ?? []))
        case "conflict":
            let conflict = try git.conflict(arg())
            return try encoder.encode(ConflictDetails(conflict))
        case "acceptConflictBlock":
            let path = try arg()
            let blockIndex = try arg(1)
            let side = try arg(2)
            var conflict = try git.conflict(path)
            guard conflict.editable, let result = request.text,
                  conflict.index == request.conflict?.index, conflict.original == request.conflict?.original,
                  let index = Int(blockIndex), ["2", "3"].contains(side),
                  let block = Conflict.blocks(in: result).first(where: { $0.id == index }) else {
                throw GitFailure(message: "This conflict changed. Refresh before resolving it.")
            }
            conflict.result = result
            conflict.accept(block, ours: side == "2")
            return try encoder.encode(ConflictDetails(conflict))
        case "resolve":
            var conflict = try git.conflict(arg())
            guard conflict.index == request.conflict?.index, conflict.original == request.conflict?.original else {
                throw GitFailure(message: "This conflict changed. Refresh before resolving it.")
            }
            if let result = request.text {
                conflict.result = result
                try git.resolve(conflict)
            } else {
                let side = try arg(1)
                guard ["2", "3"].contains(side) else { throw GitFailure(message: "Choose a conflict side.") }
                try git.resolve(conflict, side: Int(side))
            }
        case "rebase":
            let branch = try git.run(["symbolic-ref", "--quiet", "--short", "HEAD"]).droppingFinalNewline
            guard try branch == arg(1) else { throw GitFailure(message: "The checked-out branch changed.") }
            try git.rebase(onto: arg(), stash: args.dropFirst(2).first == "stash")
        case "finishRebase":
            let action = try arg()
            guard ["--continue", "--skip", "--abort"].contains(action) else {
                throw GitFailure(message: "Invalid rebase action.")
            }
            try git.finishRebase(action)
        case "restoreSavedChanges":
            if args.first == "keep" { try git.keepStash() } else { try git.restoreStash() }
        case "plan":
            return try encoder.encode(git.rebasePlan(base: arg()))
        case "runPlan":
            guard let plan = request.plan else { throw GitFailure(message: "Missing rebase plan.") }
            try git.runRebasePlan(plan)
        case "push":
            let branch = try git.run(["symbolic-ref", "--quiet", "--short", "HEAD"]).droppingFinalNewline
            guard try branch == arg() else { throw GitFailure(message: "The checked-out branch changed.") }
            try git.push(branch: branch, to: arg(1))
        case "addWorktree":
            try git.addWorktree(at: URL(fileURLWithPath: arg()), branch: arg(1), newBranch: args.dropFirst(2).first == "new")
        case "removeWorktree":
            let path = try arg()
            guard let tree = try git.worktrees().first(where: { $0.id == path }) else {
                throw GitFailure(message: "Worktree was removed.")
            }
            try git.removeWorktree(tree)
        case "createStash":
            try git.createStash(message: request.text ?? "", includeUntracked: args.contains("untracked"))
        case "showStash":
            return try encoder.encode(git.showStash(stash()))
        case "applyStash":
            try git.applyStash(stash(), index: args.contains("index"), remove: args.contains("pop"))
        case "dropStash":
            try git.dropStash(stash())
        case "pullRequests":
            let remote = try arg()
            let address = try git.run(["remote", "get-url", "--", remote]).droppingFinalNewline
            guard let remote = GitHubRemote(name: remote, address: address) else {
                throw GitFailure(message: "Choose a GitHub.com remote.")
            }
            let service = GitHubPullRequests(git: git, remote: remote)
            let action = try arg(1)
            if action == "list" { return try encoder.encode(service.list()) }
            if action == "draft" {
                return try encoder.encode(service.createDraft(title: arg(2), body: request.text ?? "",
                                                               head: arg(3), base: arg(4)))
            }
            guard let pr = request.request else { throw GitFailure(message: "Choose a pull request.") }
            switch action {
            case "diff": return try encoder.encode(service.diff(pr))
            case "checkout": try service.checkout(pr)
            case "approve": try service.approve(pr)
            case "squash": try service.squashMerge(pr)
            default: throw GitFailure(message: "Unknown pull request action.")
            }
        default:
            throw GitFailure(message: "Unknown KitGit action.")
        }
        return Data("null".utf8)
    }
}

private struct Status: Encodable {
    let root: String
    let branch: String
    let branches: [Branch]
    let worktrees: [Worktree]
    let tags: [String]
    let stashes: [Stash]
    let rows: [GraphRow]
    let width: Int
    let staged: [String]
    let unstaged: [String]
    let conflicts: [String]
    let remotes: [String]
    let github: [GitHubRemote]
    let operation: String?
    let savedChanges: Bool
    let dirty: Bool
    let canLoadMore: Bool

    init(_ repo: Repository) {
        root = repo.root.path
        branch = repo.branch
        branches = repo.branches
        worktrees = repo.worktrees
        tags = repo.tags
        stashes = repo.stashes
        rows = repo.graph.rows
        width = repo.graph.width
        staged = repo.staged
        unstaged = repo.unstaged
        conflicts = repo.conflicts
        remotes = repo.remotes
        github = repo.gitHubRemotes
        operation = repo.rebasing ? "rebase" : repo.merging ? "merge" : repo.replayOperation
        savedChanges = repo.savedChanges
        dirty = repo.dirty
        canLoadMore = repo.canLoadMore
    }
}

private struct Inspection: Encodable {
    struct Snapshot: Encodable {
        let text: String?
        let image: Data?
        let tokens: [[Int]]

        init(_ value: FileSnapshot, highlighter: CodeHighlight) {
            // shortcut: skip syntax parsing for large previews until highlighting can run on visible lines.
            if case let .text(content) = value, content.utf16.count <= 200_000 {
                tokens = highlighter.tokens(in: content)
            } else {
                tokens = []
            }
            switch value {
            case let .text(content): text = content; image = nil
            case let .binary(data): text = "Binary file"; image = data
            case .absent: text = "File is absent"; image = nil
            case .tooLarge: text = "File exceeds the 12 MB preview limit"; image = nil
            case .unavailable: text = "File preview unavailable"; image = nil
            }
        }
    }

    let before: Snapshot
    let after: Snapshot
    struct SplitRow: Encodable {
        let left: String?
        let right: String?
    }

    let diff: String
    let split: [SplitRow]
    let lines: [Int]
    let inline: [Int: [[Int]]]

    init(_ inspection: FileInspection, path: String) {
        let highlighter = CodeHighlight(path: path)
        before = Snapshot(inspection.before, highlighter: highlighter)
        after = Snapshot(inspection.after, highlighter: highlighter)
        var ranges: [Int: [[Int]]] = [:]
        for hunk in inspection.hunks {
            for line in hunk.lines {
                guard let changes = hunk.changes[line.id] else { continue }
                var offset = 1
                for (index, character) in line.source.text.dropFirst().enumerated() {
                    let length = String(character).utf16.count
                    if changes.contains(index) { ranges[line.id, default: []].append([offset, length]) }
                    offset += length
                }
            }
        }
        inline = ranges
        diff = inspection.patch.raw
        func format(_ line: FileInspection.NumberedHunk.Line?, number: Int?) -> String? {
            guard let line else { return nil }
            let label = number.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, 6 - label.count)) + label + " " + line.source.text
        }
        split = inspection.hunks.flatMap { hunk in
            [SplitRow(left: hunk.header, right: hunk.header)] + hunk.pairs.map { pair in
                SplitRow(left: format(pair.left, number: pair.left?.old), right: format(pair.right, number: pair.right?.new))
            }
        }
        lines = inspection.patch.supportsSelection
            ? inspection.patch.hunks.flatMap(\.lines).filter(\.selectable).map(\.id) : []
    }
}

private struct ConflictDetails: Encodable {
    let version: DesktopBridge.ConflictVersion
    let ours: String?
    let theirs: String?
    let result: String
    let editable: Bool
    let blocks: [[Int]]

    init(_ conflict: Conflict) {
        version = .init(index: conflict.index, original: conflict.original)
        ours = conflict.ours
        theirs = conflict.theirs
        result = conflict.result
        editable = conflict.editable
        blocks = Conflict.blocks(in: result).map { [$0.id, $0.end] }
    }
}
