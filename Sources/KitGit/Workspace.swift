import AppKit
import SwiftUI

@MainActor
final class Workspace: ObservableObject {
    struct File: Equatable {
        let path: String
        let staged: Bool
    }

    @Published var repo: Repository?
    @Published var tabs: [URL] = []
    @Published var stashPreview: Stash?
    @Published var stashDiff = ""
    private var drafts: [URL: String] = [:]
    @Published var busy = false
    @Published var error: String?
    @Published var file: File?
    @Published var inspection: FileInspection?
    @Published var selectedLines: Set<Int> = []
    @Published var conflict: Conflict?
    @Published var commit: Commit?
    @Published var commitDetail = ""
    @Published var commitFiles: [String] = []
    @Published var commitFile: String?
    @Published var history: [Commit]?
    @Published var historyTitle = ""
    @Published var attribution: String?
    @Published var message = ""
    private var limit = 300

    private func work<T: Sendable>(_ operation: @escaping @Sendable () throws -> T,
                                   done: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { done(try await Task.detached(priority: .userInitiated, operation: operation).value) }
            catch { self.error = error.localizedDescription }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Open Repository"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !busy else { return }
        if let root = repo?.root { drafts[root] = message }
        work({
            try Repository(git: Git.open(url), limit: 300)
        }, done: { repo in
            self.limit = 300
            self.repo = repo
            self.message = self.drafts[repo.root] ?? ""
            self.clearSelection()
            if !self.tabs.contains(repo.root) { self.tabs.append(repo.root) }
            self.saveTabs()
        })
    }

    func close(_ url: URL) {
        guard !busy, let index = tabs.firstIndex(of: url) else { return }
        if repo?.root == url {
            drafts[url] = message
            repo = nil
            message = ""
            clearSelection()
        }
        tabs.remove(at: index)
        saveTabs()
        if repo == nil, !tabs.isEmpty { open(tabs[min(index, tabs.count - 1)]) }
    }

    func reopen() {
        guard tabs.isEmpty && repo == nil else { return }
        let defaults = UserDefaults.standard
        tabs = (defaults.stringArray(forKey: "repositoryTabs") ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let path = defaults.string(forKey: "lastRepository"),
           FileManager.default.fileExists(atPath: path) {
            open(URL(fileURLWithPath: path, isDirectory: true))
        } else if let first = tabs.first {
            open(first)
        }
    }

    private func saveTabs() {
        UserDefaults.standard.set(tabs.map(\.path), forKey: "repositoryTabs")
        UserDefaults.standard.set(repo?.root.path, forKey: "lastRepository")
    }

    func createRepository(clone source: String? = nil) {
        guard !busy else { return }
        let panel = NSSavePanel()
        panel.title = source == nil ? "New Repository Location" : "Clone Destination"
        panel.prompt = source == nil ? "Create Repository" : "Clone"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work({
            let parent = Git(root: url.deletingLastPathComponent())
            let manager = FileManager.default
            if manager.fileExists(atPath: url.path),
               try !manager.contentsOfDirectory(atPath: url.path).isEmpty {
                throw GitFailure(message: "Choose a new or empty directory.")
            }
            if let source {
                try parent.run(["-c", "protocol.ext.allow=never", "clone", "--", source, url.path])
            } else {
                try parent.run(["init", "--", url.path])
            }
        }, done: { _ in Task { self.open(url) } })
    }

    func addWorktree(branch: String, newBranch: Bool) {
        guard !branch.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Choose Worktree Location"
        panel.prompt = "Create Worktree"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = branch.split(separator: "/").last.map(String.init) ?? "worktree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { try $0.addWorktree(at: url, branch: branch, newBranch: newBranch) } after: {
            Task { self.open(url) }
        }
    }

    func removeWorktree(_ tree: Worktree) {
        change { try $0.removeWorktree(tree) } after: {
            self.tabs.removeAll { $0.resolvingSymlinksInPath() == tree.url.resolvingSymlinksInPath() }
            self.saveTabs()
        }
    }

    func selectStash(_ stash: Stash) {
        guard let root = repo?.root else { return }
        work({ try Git(root: root).showStash(stash) }, done: { diff in
            self.clearSelection()
            self.stashPreview = stash
            self.stashDiff = diff
        })
    }

    func closeFileViewer() {
        file = nil
        inspection = nil
        selectedLines = []
        commitFile = nil
        conflict = nil
    }

    func clearSelection() {
        closeFileViewer()
        commit = nil
        stashPreview = nil
        history = nil
        attribution = nil
    }

    func listFiles(done: @escaping ([String]) -> Void) {
        guard let root = repo?.root else { return }
        work({
            let paths = try Git(root: root).paths(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            return Array(Set(paths)).sorted()
        }, done: done)
    }

    func selectFile(_ item: File) {
        guard let root = repo?.root else { return }
        work({ try Git(root: root).inspectFile(item.path, staged: item.staged) }, done: { inspection in
            self.clearSelection()
            self.file = item
            self.inspection = inspection
        })
    }

    func searchCommits(_ query: String) {
        guard let root = repo?.root, !query.isEmpty else { return }
        work({ try Git(root: root).searchCommits(query) }, done: { results in
            self.clearSelection()
            self.historyTitle = "Search: " + query
            self.history = results
        })
    }

    func showFileHistory(_ path: String, at revision: String = "HEAD") {
        guard let root = repo?.root else { return }
        work({
            try Git(root: root).commits(["--follow", "-n", "100", revision, "--", path])
        }, done: { results in
            self.clearSelection()
            self.historyTitle = "History: " + path
            self.history = results
        })
    }

    func blameFile(_ path: String, at revision: String = "HEAD") {
        guard let root = repo?.root else { return }
        work({
            try Git(root: root).run(["blame", "--date=short", revision, "--", path])
        }, done: { text in
            self.clearSelection()
            self.historyTitle = "Blame: " + path
            self.attribution = text
        })
    }

    func prepareRebase(onto commit: Commit, done: @escaping (RebasePlan) -> Void) {
        guard let root = repo?.root else { return }
        work({ try Git(root: root).rebasePlan(base: commit.id) }, done: done)
    }

    func selectRef(_ ref: String) {
        guard let root = repo?.root else { return }
        work({
            let git = Git(root: root)
            let hash = try git.run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).droppingFinalNewline
            let details = try git.run(["show", "-s", "--format=%P%x00%D%x00%an%x00%as%x00%s", hash, "--"])
            let fields = details.droppingFinalNewline.components(separatedBy: "\0")
            guard fields.count == 5 else { throw GitFailure(message: "Git returned invalid commit details.") }
            return Commit(id: hash, parents: fields[0].split(separator: " ").map(String.init),
                          refs: fields[1], subject: fields[4], author: fields[2], date: fields[3])
        }, done: { commit in Task { self.selectCommit(commit) } })
    }

    func selectCommit(_ item: Commit) {
        guard let root = repo?.root else { return }
        work({
            let git = Git(root: root)
            let body = try git.run(["show", "-s", "--format=%B", item.id, "--"])
            let files = try git.paths(["show", "--format=", "--first-parent", "--diff-merges=first-parent",
                                       "--no-renames", "--name-only", "-z", item.id, "--"])
            return (body.trimmingCharacters(in: .newlines), files)
        }, done: { body, files in
            self.clearSelection()
            self.commit = item
            self.commitDetail = body
            self.commitFiles = files
        })
    }

    func selectCommitFile(_ path: String) {
        guard let root = repo?.root, let commit else { return }
        work({ try Git(root: root).inspectFile(path, at: commit) }, done: { inspection in
            self.commitFile = path
            self.inspection = inspection
        })
    }

    func selectConflict(_ path: String) {
        guard let root = repo?.root else { return }
        work({ try Git(root: root).conflict(path) }, done: {
            self.clearSelection()
            self.conflict = $0
        })
    }

    func change(conflictsExpected: Bool = false, _ operation: @escaping @Sendable (Git) throws -> Void, after: (() -> Void)? = nil) {
        guard let root = repo?.root else { return }
        let count = limit
        work({
            let git = Git(root: root)
            let failure: String?
            do { try operation(git); failure = nil }
            catch { failure = error.localizedDescription }
            return (try Repository(git: git, limit: count), failure)
        }, done: { repo, failure in
            self.repo = repo
            self.clearSelection()
            self.error = conflictsExpected && repo.operationInProgress && !repo.conflicts.isEmpty ? nil : failure
            if failure == nil { after?() }
        })
    }

    func refresh(loadMore: Bool = false) {
        guard !busy else { return }
        if loadMore { limit += 300 }
        change { _ in }
    }

    func stage(_ file: File) {
        change { try $0.stageFile(file.path, unstage: file.staged) }
    }

    func stageSelection() {
        guard let patch = inspection?.patch, let file, !file.staged else { return }
        let lines = selectedLines
        change { git in
            try git.stageLines(file.path, originalDiff: patch.raw, lines: lines)
        } after: {
            if self.repo?.unstaged.contains(file.path) == true { self.selectFileAfterRefresh(file) }
        }
    }

    private func selectFileAfterRefresh(_ file: File) {
        Task { self.selectFile(file) }
    }

    func makeCommit() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        change { git in
            try git.run(["commit", "-F", "-"], input: text)
        } after: { self.message = "" }
    }

    func resolve(_ conflict: Conflict, side: Int? = nil) {
        change { try $0.resolve(conflict, side: side) }
    }
}
