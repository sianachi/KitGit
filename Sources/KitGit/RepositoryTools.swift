import Foundation

struct Worktree: Identifiable, Codable {
    let id: String
    let branch: String?
    let main: Bool
    let locked: Bool
    let bare: Bool
    let missing: Bool

    var url: URL { URL(fileURLWithPath: id, isDirectory: true) }
    var name: String { url.lastPathComponent }
}

struct Stash: Identifiable, Codable {
    let id: String
    let hash: String
    let message: String
}

extension Git {
    func commits(_ arguments: [String]) throws -> [Commit] {
        try paths(["--literal-pathspecs", "log", "--decorate=short", "-z",
                   "--format=%H%x1f%P%x1f%D%x1f%an%x1f%as%x1f%s"] + arguments).compactMap {
            let parts = $0.split(separator: "\u{1f}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6 else { return nil }
            return Commit(id: parts[0], parents: parts[1].split(separator: " ").map(String.init),
                          refs: parts[2], subject: parts[5], author: parts[3], date: parts[4])
        }
    }

    func searchCommits(_ query: String) throws -> [Commit] {
        let matches = try commits(["--all", "--fixed-strings", "--regexp-ignore-case",
                                   "--grep=" + query, "-n", "100"])
        if (4...64).contains(query.count), query.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }), let result = try? commits(["-n", "1", query + "^{commit}", "--"]).first,
           !matches.contains(where: { $0.id == result.id }) {
            return [result] + matches
        }
        return matches
    }

    func push(branch: String, to remote: String) throws {
        let ref = "refs/heads/" + branch
        guard try run(["symbolic-ref", "--quiet", "HEAD"]).droppingFinalNewline == ref else {
            throw GitFailure(message: "The checked-out branch changed. Refresh before pushing.")
        }
        guard try run(["remote"]).split(separator: "\n").contains(Substring(remote)) else {
            throw GitFailure(message: "This remote is no longer configured.")
        }
        try run(["-c", "remote." + remote + ".mirror=false", "push", "--no-follow-tags",
                 "--recurse-submodules=no", "--", remote, ref + ":" + ref])
    }

    func worktrees() throws -> [Worktree] {
        let raw = try run(["worktree", "list", "--porcelain", "-z"])
        return raw.components(separatedBy: "\0\0").enumerated().compactMap { index, record in
            let fields = record.split(separator: "\0")
            guard let path = fields.first, path.hasPrefix("worktree ") else { return nil }
            let branch = fields.first { $0.hasPrefix("branch refs/heads/") }.map {
                String($0.dropFirst("branch refs/heads/".count))
            }
            let value = String(path.dropFirst("worktree ".count))
            return Worktree(id: value, branch: branch, main: index == 0,
                            locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                            bare: fields.contains("bare"),
                            missing: !FileManager.default.fileExists(atPath: value))
        }
    }

    func addWorktree(at url: URL, branch: String, newBranch: Bool) throws {
        try run(["check-ref-format", "--branch", branch])
        if newBranch {
            try run(["worktree", "add", "-b", branch, "--", url.path, "HEAD"])
        } else {
            try run(["rev-parse", "--verify", "--end-of-options", "refs/heads/" + branch])
            try run(["worktree", "add", "--", url.path, branch])
        }
    }

    func removeWorktree(_ worktree: Worktree) throws {
        guard let current = try worktrees().first(where: { $0.id == worktree.id }),
              !current.main, !current.locked, !current.missing, current.url != root else {
            throw GitFailure(message: "Choose an unlocked linked worktree from another tab.")
        }
        let target = try Git.open(current.url)
        guard target.root.resolvingSymlinksInPath() == current.url.resolvingSymlinksInPath(),
              try target.run(["status", "--porcelain", "--ignored", "--untracked-files=all", "-z"]).isEmpty,
              try !target.operationInProgress(), try target.pendingStash() == nil else {
            throw GitFailure(message: "This worktree has changes, ignored files, or an active operation. Open it and review its state before removing it.")
        }
        try run(["worktree", "remove", "--", current.id])
    }

    func stashes() throws -> [Stash] {
        try paths(["stash", "list", "-z", "--format=%gd%x1f%H%x1f%gs"]).compactMap {
            let fields = $0.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return Stash(id: String(fields[0]), hash: String(fields[1]), message: String(fields[2]))
        }
    }

    func createStash(message: String, includeUntracked: Bool) throws {
        guard try !operationInProgress() else {
            throw GitFailure(message: "Finish the current Git operation before stashing changes.")
        }
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if !message.isEmpty { args += ["-m", message] }
        try run(args)
    }

    func applyStash(_ stash: Stash, index: Bool, remove: Bool) throws {
        guard try !operationInProgress() else {
            throw GitFailure(message: "Finish the current Git operation before applying a stash.")
        }
        if remove { try checkStashCanDrop(stash) }
        try run(["stash", "apply"] + (index ? ["--index"] : []) + [stash.hash])
        if remove {
            do { try dropStash(stash) }
            catch {
                throw GitFailure(message: "The stash was applied and its recovery copy was kept. " + error.localizedDescription)
            }
        }
    }

    func dropStash(_ stash: Stash) throws {
        try checkStashCanDrop(stash)
        try run(["stash", "drop", stash.id])
    }

    private func checkStashCanDrop(_ stash: Stash) throws {
        let manager = FileManager.default
        let commonPath = try run(["rev-parse", "--path-format=absolute", "--git-common-dir"]).droppingFinalNewline
        let common = URL(fileURLWithPath: commonPath, isDirectory: true)
        let linked = common.appendingPathComponent("worktrees", isDirectory: true)
        let directories = manager.fileExists(atPath: linked.path)
            ? try manager.contentsOfDirectory(at: linked, includingPropertiesForKeys: nil) : []
        for directory in [common] + directories {
            let record = directory.appendingPathComponent("kitgit-rebase-stash")
            if manager.fileExists(atPath: record.path),
               try String(contentsOf: record, encoding: .utf8) == stash.hash {
                throw GitFailure(message: "KitGit is holding this stash for a rebase. Finish that rebase or keep its saved changes in the stash list first.")
            }
        }
        guard try stashes().contains(where: { $0.id == stash.id && $0.hash == stash.hash }) else {
            throw GitFailure(message: "The stash list changed. Refresh and choose the stash again.")
        }
    }

    func showStash(_ stash: Stash) throws -> String {
        try run(["stash", "show", "--include-untracked", "--patch", "--no-ext-diff", "--no-textconv", stash.hash])
    }
}
