import Foundation
import XCTest
@testable import KitGit

final class WorkflowTests: XCTestCase {
    func repository(_ body: (Git) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let git = Git(root: url)
        try git.run(["init", "-b", "main"])
        try git.run(["config", "user.name", "KitGit Test"])
        try git.run(["config", "user.email", "kitgit@example.test"])
        try git.run(["config", "commit.gpgsign", "false"])
        try git.run(["config", "core.autocrlf", "false"])
        XCTAssertTrue(try Repository(git: git, limit: 10).graph.rows.isEmpty)
        try body(git)
    }

    func write(_ text: String, _ path: String, _ git: Git) throws {
        try text.write(to: git.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func commit(_ message: String, _ git: Git) throws {
        try git.run(["add", "--all"])
        try git.run(["commit", "-m", message])
    }

    func testPartialStagingThenCommitKeepsOtherEdits() throws {
        try repository { git in
            let path = "file with spaces"
            try write("old\nmiddle\nlast\n", path, git)
            try commit("Initial", git)
            try write("first\nmiddle\nlatest\n", path, git)
            let patch = Patch(try git.diff(path, staged: false))
            let chosen = patch.hunks.flatMap(\.lines).filter { ["-old", "+first"].contains($0.text) }
            try git.stageLines(path, originalDiff: patch.raw, lines: Set(chosen.map(\.id)))
            XCTAssertEqual(try git.run(["show", ":" + path]), "first\nmiddle\nlast\n")
            try git.run(["commit", "-F", "-"], input: "Only the first edit")
            XCTAssertEqual(try git.run(["show", "HEAD:" + path]), "first\nmiddle\nlast\n")
            XCTAssertEqual(try String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8), "first\nmiddle\nlatest\n")
            let repo = try Repository(git: git, limit: 1)
            XCTAssertEqual(repo.graph.rows.first?.commit.subject, "Only the first edit")
            XCTAssertTrue(repo.canLoadMore)
        }
    }

    func testPartiallyStageUntrackedFile() throws {
        try repository { git in
            try write("first\nsecond\n", "new.txt", git)
            let patch = Patch(try git.diff("new.txt", staged: false))
            let line = try XCTUnwrap(patch.hunks.first?.lines.first { $0.text == "+second" })
            try git.stageLines("new.txt", originalDiff: patch.raw, lines: [line.id])
            XCTAssertEqual(try git.run(["show", ":new.txt"]), "second\n")
        }
    }

    func diverge(_ git: Git) throws {
        try write("base\n", "conflict.txt", git)
        try commit("Base", git)
        try git.run(["switch", "-c", "feature"])
        try write("feature\n", "conflict.txt", git)
        try commit("Feature", git)
        try git.run(["switch", "main"])
        try write("target\n", "conflict.txt", git)
        try commit("Target", git)
        try git.run(["switch", "feature"])
    }

    func testRebaseConflictAndRestoreIndex() throws {
        try repository { git in
            try diverge(git)
            try write("staged\n", "saved.txt", git)
            try git.run(["add", "--", "saved.txt"])
            try write("worktree\n", "saved.txt", git)
            try write("untracked\n", "new.txt", git)
            XCTAssertThrowsError(try git.rebase(onto: "refs/heads/main", stash: false))
            XCTAssertEqual(try git.run(["show", ":saved.txt"]), "staged\n")
            XCTAssertNil(try git.pendingStash())
            XCTAssertThrowsError(try git.rebase(onto: "refs/heads/main", stash: true))

            let reopened = try Git.open(git.root)
            let repo = try Repository(git: reopened, limit: 20)
            XCTAssertTrue(repo.rebasing)
            XCTAssertTrue(repo.savedChanges)
            XCTAssertEqual(repo.conflicts, ["conflict.txt"])
            var conflict = try reopened.conflict("conflict.txt")
            XCTAssertEqual(conflict.ours, "target\n")
            XCTAssertEqual(conflict.theirs, "feature\n")
            conflict.accept(try XCTUnwrap(Conflict.blocks(in: conflict.result).first), ours: false)
            try reopened.resolve(conflict)
            try reopened.finishRebase("--continue")
            XCTAssertFalse(try reopened.rebaseActive())
            XCTAssertNil(try reopened.pendingStash())
            XCTAssertEqual(try reopened.run(["show", "HEAD:conflict.txt"]), "feature\n")
            XCTAssertEqual(try reopened.run(["show", ":saved.txt"]), "staged\n")
            for (path, content) in [("saved.txt", "worktree\n"), ("new.txt", "untracked\n")] {
                XCTAssertEqual(try String(contentsOf: reopened.root.appendingPathComponent(path), encoding: .utf8), content)
            }
        }
    }

    func testWorktreeLifecycleProtectsLocalFiles() throws {
        try repository { git in
            try write("base\n", "tracked.txt", git)
            try write("ignored.txt\n", ".gitignore", git)
            try commit("Base", git)
            let base = git.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            let path = base.appendingPathComponent("review workspace", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }

            try git.addWorktree(at: path, branch: "review", newBranch: true)
            let entry = try XCTUnwrap(git.worktrees().first { $0.branch == "review" })
            let linked = try Git.open(path)
            XCTAssertEqual(try linked.worktrees().count, 2)
            XCTAssertEqual(try linked.run(["branch", "--show-current"]), "review\n")
            try git.run(["worktree", "lock", "--", entry.id])
            XCTAssertThrowsError(try git.removeWorktree(entry))
            try git.run(["worktree", "unlock", "--", entry.id])
            try write("saved", "ignored.txt", linked)
            XCTAssertThrowsError(try git.removeWorktree(entry))
            try FileManager.default.removeItem(at: linked.root.appendingPathComponent("ignored.txt"))
            try git.removeWorktree(entry)
            XCTAssertEqual(try git.worktrees().count, 1)
            XCTAssertEqual(try git.run(["branch", "--list", "review"]).trimmingCharacters(in: .whitespacesAndNewlines), "review")
            try git.addWorktree(at: path, branch: "review", newBranch: false)
            XCTAssertEqual(try Git.open(path).run(["branch", "--show-current"]), "review\n")
            try git.removeWorktree(try XCTUnwrap(git.worktrees().first { $0.branch == "review" }))
        }
    }

    func testStashPreviewApplyPopAndDrop() throws {
        try repository { git in
            try write("base\n", "tracked.txt", git)
            try commit("Base", git)
            try write("staged\n", "tracked.txt", git)
            try git.run(["add", "--", "tracked.txt"])
            try write("untracked\n", "new.txt", git)
            try git.createStash(message: "First", includeUntracked: true)
            let first = try XCTUnwrap(git.stashes().first)
            XCTAssertTrue(try git.showStash(first).contains("+untracked"))
            XCTAssertTrue(try git.run(["status", "--porcelain"]).isEmpty)
            try git.applyStash(first, index: true, remove: false)
            XCTAssertEqual(try git.run(["show", ":tracked.txt"]), "staged\n")
            XCTAssertEqual(try git.stashes().count, 1)
            try git.createStash(message: "Second", includeUntracked: true)
            XCTAssertThrowsError(try git.dropStash(first))
            let second = try XCTUnwrap(git.stashes().first)
            try git.applyStash(second, index: true, remove: true)
            XCTAssertEqual(try git.stashes().map(\.hash), [first.hash])
            let record = try git.gitPath("kitgit-rebase-stash")
            try first.hash.write(to: record, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try git.dropStash(try XCTUnwrap(git.stashes().first)))
            try git.keepStash()
            try git.dropStash(try XCTUnwrap(git.stashes().first))
            XCTAssertTrue(try git.stashes().isEmpty)
            XCTAssertEqual(try git.paths(["ls-files", "--others", "-z"]), ["new.txt"])
        }
    }

    func testPushAndFastForwardPullThroughLocalRemote() throws {
        try repository { git in
            try write("base\n", "tracked.txt", git)
            try commit("Base", git)
            let parent = git.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            let outside = Git(root: parent)
            let bare = parent.appendingPathComponent("remote.git", isDirectory: true)
            let checkout = parent.appendingPathComponent("clone", isDirectory: true)
            try outside.run(["init", "--bare", "-b", "main", "--", bare.path])
            try git.run(["remote", "add", "origin", bare.path])
            try git.run(["config", "remote.origin.mirror", "true"])
            try git.run(["branch", "private-branch"])
            try git.push(branch: "main", to: "origin")
            XCTAssertTrue(try Git(root: bare).run(["branch", "--list", "private-branch"]).isEmpty)
            try outside.run(["clone", "--", bare.path, checkout.path])
            try write("updated\n", "tracked.txt", git)
            try commit("Update", git)
            try git.push(branch: "main", to: "origin")
            let clone = try Git.open(checkout)
            try clone.run(["fetch", "--all"])
            try clone.run(["pull", "--ff-only", "--no-rebase"])
            XCTAssertEqual(try clone.run(["show", "HEAD:tracked.txt"]), "updated\n")
        }
    }

    func testInteractiveRebaseReordersAndFixesUpCommits() throws {
        try repository { git in
            try write("base\n", "base.txt", git)
            try commit("Base", git)
            let base = try git.run(["rev-parse", "HEAD"]).droppingFinalNewline
            try write("A\n", "a.txt", git)
            try commit("A", git)
            try write("B\n", "b.txt", git)
            try commit("B", git)
            try write("extra\n", "extra.txt", git)
            try commit("Extra", git)
            var plan = try git.rebasePlan(base: base)
            XCTAssertEqual(plan.entries.map(\.subject), ["A", "B", "Extra"])
            plan.entries.swapAt(0, 1)
            plan.entries[2].action = .fixup
            try git.runRebasePlan(plan)
            XCTAssertEqual(try git.run(["log", "-2", "--format=%s"]), "A\nB\n")
            XCTAssertEqual(try git.run(["show", "HEAD:extra.txt"]), "extra\n")
            XCTAssertThrowsError(try git.runRebasePlan(plan))
        }
    }

    func testCommitSearchFindsMessageAndHash() throws {
        try repository { git in
            try write("base\n", "notes.txt", git)
            try commit("Build [foundation]", git)
            let head = try git.run(["rev-parse", "HEAD"]).droppingFinalNewline
            XCTAssertEqual(try git.searchCommits("[FOUNDATION]").map(\.id), [head])
            XCTAssertEqual(try git.searchCommits(String(head.prefix(8))).map(\.id), [head])
            XCTAssertTrue(try git.searchCommits("absent").isEmpty)
            XCTAssertEqual(try git.commits(["--follow", "HEAD", "--", "notes.txt"]).map(\.id), [head])
        }
    }

    func testGitHubActionsAddressTheExplicitRemoteAndCommit() throws {
        try repository { git in
            try git.run(["remote", "add", "origin", "git@github.com:example/team.git"])
            let model = try Repository(git: git, limit: 20)
            let remote = try XCTUnwrap(model.gitHubRemotes.first)
            XCTAssertEqual(remote.slug, "example/team")
            XCTAssertNil(GitHubRemote(name: "wrong", address: "https://github.com.example.org/org/repo"))

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            #if !os(Windows)
            let tool = directory.appendingPathComponent("gh")
            let captured = git.root.appendingPathComponent("arguments.txt")
            try """
                #!/bin/sh
                printf '%s\n' "$@" > arguments.txt
                case "$1" in
                    pr) printf '%s' '[{"number":8,"title":"Changes","body":"Details","author":{"login":"dev"},"headRefName":"feature","headRefOid":"abcd1234","baseRefName":"main","isDraft":false}]' ;;
                    api) printf '%s' '{"merged":true,"message":"Merged"}' ;;
                esac
                """.write(to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            let client = GitHubPullRequests(git: git, remote: remote, executable: tool)
            let pull = try XCTUnwrap(client.list().first)
            XCTAssertEqual(pull.number, 8)
            XCTAssertTrue(try String(contentsOf: captured, encoding: .utf8).contains("--repo\ngithub.com/example/team"))
            try client.approve(pull)
            XCTAssertTrue(try String(contentsOf: captured, encoding: .utf8).contains("repos/example/team/pulls/8/reviews"))
            XCTAssertTrue(try String(contentsOf: captured, encoding: .utf8).contains("commit_id=abcd1234"))
            try client.squashMerge(pull)
            let args = try String(contentsOf: captured, encoding: .utf8)
            XCTAssertTrue(args.contains("repos/example/team/pulls/8/merge"))
            XCTAssertTrue(args.contains("sha=abcd1234"))
            #endif
        }
    }

    func testFileInspectionReadsTheCorrectVersions() throws {
        try repository { git in
            let path = "versions.txt"
            try write("common\nhead\n", path, git)
            try commit("Base", git)
            try write("common\nindex\n", path, git)
            try git.run(["add", "--", path])
            try write("common\nworking\nextra\n", path, git)

            let working = try git.inspectFile(path, staged: false)
            XCTAssertEqual(working.before, .text("common\nindex\n"))
            XCTAssertEqual(working.after, .text("common\nworking\nextra\n"))
            let hunk = try XCTUnwrap(working.hunks.first)
            XCTAssertEqual(hunk.pairs.map { $0.left?.old }, [1, 2, nil])
            XCTAssertEqual(hunk.pairs.map { $0.right?.new }, [1, 2, 3])
            XCTAssertEqual(hunk.pairs[1].left?.source.text, "-index")
            XCTAssertEqual(hunk.pairs[1].right?.source.text, "+working")

            let index = try git.inspectFile(path, staged: true)
            XCTAssertEqual(index.before, .text("common\nhead\n"))
            XCTAssertEqual(index.after, .text("common\nindex\n"))
            try git.run(["commit", "-m", "Index snapshot"])
            let tip = try XCTUnwrap(git.commits(["-n", "1", "HEAD"]).first)
            let historical = try git.inspectFile(path, at: tip)
            XCTAssertEqual(historical.before, index.before)
            XCTAssertEqual(historical.after, index.after)
        }
    }

    func testBinaryPreviewPreservesBlobBytesAndDeletedFiles() throws {
        try repository { git in
            let path = "sample.bin"
            let bytes = Data([0, 255, 10, 13, 5])
            try bytes.write(to: git.root.appendingPathComponent(path))
            XCTAssertEqual(try git.inspectFile(path, staged: false).after, .binary(bytes))
            try commit("Sample bytes", git)
            try FileManager.default.removeItem(at: git.root.appendingPathComponent(path))
            let deletion = try git.inspectFile(path, staged: false)
            XCTAssertEqual(deletion.before, .binary(bytes))
            XCTAssertEqual(deletion.after, .absent)
        }
    }

    func testInlineDiffFindsIndependentChangesAndPreservesSyntaxColor() throws {
        let old = #"let count = 10; let name = "🐱""#
        let new = #"let count = 20; let name = "🐶""#
        let change = InlineChange(old: old, new: new)
        XCTAssertEqual(String(change.old.sorted().map { Array(old)[$0] }), "1🐱")
        XCTAssertEqual(String(change.new.sorted().map { Array(new)[$0] }), "2🐶")

        #if !os(macOS)
        let tokens = CodeHighlight(path: "update.swift").tokens(in: new)
        XCTAssertTrue(tokens.contains([0, 3, 3]))
        #else
        let styled = CodeHighlight(path: "update.swift").style(new, changed: change.new, background: .red)
        XCTAssertEqual(String(styled.characters), new)
        let runs = styled.runs
        XCTAssertTrue(runs.contains { $0.foregroundColor != nil && String(styled[$0.range].characters) == "let" })
        let marked = runs.filter { $0.backgroundColor != nil }.map { String(styled[$0.range].characters) }.joined()
        XCTAssertEqual(marked, "2🐶")
        #endif
    }

    func testSkipAndAbortRestoreSavedWork() throws {
        for action in ["--skip", "--abort"] {
            try repository { git in
                try diverge(git)
                let original = try git.run(["rev-parse", "HEAD"])
                try write("untracked\n", "new.txt", git)
                XCTAssertThrowsError(try git.rebase(onto: "refs/heads/main", stash: true))
                try git.finishRebase(action)
                XCTAssertFalse(try git.rebaseActive())
                XCTAssertNil(try git.pendingStash())
                let expected = action == "--skip" ? try git.run(["rev-parse", "main"]) : original
                XCTAssertEqual(try git.run(["rev-parse", "HEAD"]), expected)
                XCTAssertEqual(try git.paths(["ls-files", "--others", "-z"]), ["new.txt"])
            }
        }
    }
}
