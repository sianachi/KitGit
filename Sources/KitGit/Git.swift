import Foundation

struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Git {
    let root: URL

    @discardableResult
    func run(_ args: [String], input: String? = nil, accepting: Set<Int32> = [0],
             environment: [String: String] = [:], executable: URL? = nil) throws -> String {
        String(decoding: try bytes(args, input: input, accepting: accepting,
                                   environment: environment, executable: executable), as: UTF8.self)
    }

    func bytes(_ args: [String], input: String? = nil, accepting: Set<Int32> = [0],
               environment: [String: String] = [:], executable: URL? = nil) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let output = folder.appendingPathComponent("output")
        let errors = folder.appendingPathComponent("errors")
        let stdin = folder.appendingPathComponent("input")
        try Data().write(to: output)
        try Data().write(to: errors)
        try Data((input ?? "").utf8).write(to: stdin)
        let out = try FileHandle(forWritingTo: output)
        let err = try FileHandle(forWritingTo: errors)
        let source = try FileHandle(forReadingFrom: stdin)
        defer { try? out.close(); try? err.close(); try? source.close() }

        let process = Process()
        #if os(Windows)
        guard let program = executable ?? Self.windowsExecutable("git.exe") else {
            throw GitFailure(message: "Install Git for Windows and add it to PATH.")
        }
        process.executableURL = program
        #else
        process.executableURL = executable ?? URL(fileURLWithPath: "/usr/bin/git")
        #endif
        process.currentDirectoryURL = root
        process.arguments = (executable == nil ? ["--no-pager", "-c", "color.ui=false"] : []) + args
        var env = ProcessInfo.processInfo.environment
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                     "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"] {
            env.removeValue(forKey: name)
        }
        env["LC_ALL"] = "C"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = ":"
        env["GIT_SEQUENCE_EDITOR"] = ":"
        process.environment = env.merging(environment) { _, value in value }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = source
        #if !os(macOS)
        // Foundation can miss the run-loop wakeup in waitUntilExit after a short process exits.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        finished.wait()
        #else
        try process.run()
        process.waitUntilExit()
        #endif
        let stdout = try Data(contentsOf: output)
        guard accepting.contains(process.terminationStatus) else {
            let stderr = String(decoding: try Data(contentsOf: errors), as: UTF8.self)
            throw GitFailure(message: (stderr.isEmpty ? String(decoding: stdout, as: UTF8.self) : stderr).trimmingCharacters(in: .newlines))
        }
        return stdout
    }

    #if os(Windows)
    static func windowsExecutable(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value
        let directories = (path ?? "").split(separator: ";")
        return directories.lazy
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), isDirectory: true) }
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    #endif

    static func open(_ url: URL) throws -> Git {
        let path = try Git(root: url).run(["rev-parse", "--show-toplevel"]).droppingFinalNewline
        return Git(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    func paths(_ args: [String]) throws -> [String] {
        try run(args).split(separator: "\0").map(String.init)
    }

    func diff(_ path: String, staged: Bool) throws -> String {
        let options = ["--no-ext-diff", "--no-textconv", "--no-renames", "--src-prefix=a/",
                       "--dst-prefix=b/", "--output-indicator-new=+", "--output-indicator-old=-",
                       "--output-indicator-context= "]
        let diff = try run(["--literal-pathspecs", "diff"] + options + (staged ? ["--cached"] : []) + ["--", path])
        if !staged, diff.isEmpty, !(try paths(["--literal-pathspecs", "ls-files", "--others", "--exclude-standard", "-z", "--", path])).isEmpty {
            return try run(["diff", "--no-index"] + options + ["--", "/dev/null", path], accepting: [0, 1])
        }
        return diff
    }

    func stageFile(_ path: String, unstage: Bool) throws {
        if unstage {
            let head = try run(["rev-parse", "-q", "--verify", "HEAD"], accepting: [0, 1])
            if head.isEmpty {
                try run(["update-index", "--force-remove", "--", path])
            } else {
                try run(["--literal-pathspecs", "restore", "--staged", "--", path])
            }
        } else {
            try run(["--literal-pathspecs", "add", "--", path])
        }
    }

    func stageLines(_ path: String, originalDiff: String, lines: Set<Int>) throws {
        let currentDiff = try diff(path, staged: false)
        guard currentDiff == originalDiff else {
            throw GitFailure(message: "The diff changed on disk. Select the lines again.")
        }
        try run(["-c", "apply.ignoreWhitespace=no", "apply", "--cached", "--whitespace=nowarn", "--", "-"],
                input: Patch(currentDiff).selected(lines))
    }

    func gitPath(_ name: String) throws -> URL {
        let path = try run(["rev-parse", "--path-format=absolute", "--git-path", name]).droppingFinalNewline
        return URL(fileURLWithPath: path)
    }

    func rebaseActive() throws -> Bool {
        for name in ["rebase-merge", "rebase-apply"] {
            let path = try gitPath(name)
            if FileManager.default.fileExists(atPath: path.path) { return true }
        }
        return false
    }

    func operationInProgress() throws -> Bool {
        if try rebaseActive() { return true }
        for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"] {
            if try FileManager.default.fileExists(atPath: gitPath(name).path) { return true }
        }
        return false
    }

    func rebase(onto ref: String, stash: Bool) throws {
        guard try !operationInProgress() else {
            throw GitFailure(message: "Finish the current Git operation before rebasing.")
        }
        guard try pendingStash() == nil else {
            throw GitFailure(message: "Restore or keep the saved changes before starting another rebase.")
        }
        let target = try run(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).droppingFinalNewline
        let dirty = try !run(["status", "--porcelain", "-z"]).isEmpty
        if dirty {
            guard stash else { throw GitFailure(message: "The working tree changed. Review it before rebasing.") }
            let before = try run(["rev-parse", "-q", "--verify", "refs/stash"], accepting: [0, 1])
            try run(["stash", "push", "--include-untracked", "-m", "KitGit before rebase"])
            let after = try run(["rev-parse", "--verify", "refs/stash"]).droppingFinalNewline
            guard after != before.droppingFinalNewline else {
                throw GitFailure(message: "Git did not create a stash. Check the working tree.")
            }
            try after.write(to: gitPath("kitgit-rebase-stash"), atomically: true, encoding: .utf8)
        }
        do {
            try run(["-c", "rebase.autoStash=false", "-c", "rebase.autoSquash=false",
                     "-c", "rebase.updateRefs=false", "rebase", "--merge", target])
        } catch {
            if try !rebaseActive() { try restoreStash() }
            throw error
        }
        try restoreStash()
    }

    func finishRebase(_ action: String) throws {
        try run(["rebase", action])
        if try !rebaseActive() { try restoreStash() }
    }

    func pendingStash() throws -> String? {
        let path = try gitPath("kitgit-rebase-stash")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let hash = try String(contentsOf: path, encoding: .utf8)
        guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
            throw GitFailure(message: "The KitGit stash record is invalid.")
        }
        return hash
    }

    func keepStash() throws {
        try FileManager.default.removeItem(at: gitPath("kitgit-rebase-stash"))
    }

    func restoreStash() throws {
        guard let hash = try pendingStash() else { return }
        do {
            try run(["stash", "apply", "--index", hash])
        } catch {
            throw GitFailure(message: "Git could not restore the saved changes cleanly. The stash is still saved.\n\n" + error.localizedDescription)
        }
        // Keep the original stash as a recovery copy, even if another client changes the stash list.
        try keepStash()
    }

    func conflict(_ path: String) throws -> Conflict {
        let index = try paths(["--literal-pathspecs", "ls-files", "-u", "-z", "--", path])
        let stages = Set(index.compactMap { $0.split(separator: "\t", maxSplits: 1).first?.split(separator: " ").last.map(String.init) })
        let url = root.appendingPathComponent(path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let insideRepo = url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
        let current = values?.isRegularFile == true && values?.isSymbolicLink != true && insideRepo
            ? try? Data(contentsOf: url) : nil
        let ours = stages.contains("2") ? try run(["show", ":2:" + path]) : nil
        let theirs = stages.contains("3") ? try run(["show", ":3:" + path]) : nil
        let text = current.flatMap { String(data: $0, encoding: .utf8) }
        let regular = index.allSatisfy { $0.hasPrefix("100644 ") || $0.hasPrefix("100755 ") }
        return Conflict(path: path, index: index, original: current, ours: ours, theirs: theirs,
                        result: text ?? "", editable: regular && text != nil && !(text?.contains("\0") ?? true))
    }

    func resolve(_ conflict: Conflict, side: Int? = nil) throws {
        let path = conflict.path
        let current = try self.conflict(path)
        guard !current.index.isEmpty, current.index == conflict.index, current.original == conflict.original else {
            throw GitFailure(message: "This conflict changed on disk. Refresh before resolving it.")
        }
        if let side {
            let stage = " \(side)\t"
            if current.index.contains(where: { $0.contains(stage) }) {
                try run(["--literal-pathspecs", "checkout", side == 2 ? "--ours" : "--theirs", "--", path])
                try run(["--literal-pathspecs", "add", "--", path])
            } else {
                try run(["--literal-pathspecs", "rm", "--", path])
            }
        } else {
            guard current.editable && conflict.editable else { throw GitFailure(message: "Choose a version to resolve this file.") }
            guard Conflict.blocks(in: conflict.result).isEmpty,
                  !conflict.result.components(separatedBy: "\n").contains(where: Conflict.isMarker) else {
                throw GitFailure(message: "Resolve every conflict marker before staging this file.")
            }
            let url = root.appendingPathComponent(path)
            try Data(conflict.result.utf8).write(to: url)
            try run(["--literal-pathspecs", "add", "--", path])
        }
    }
}

extension String {
    var droppingFinalNewline: String { utf8.last == 10 ? String(decoding: utf8.dropLast(), as: UTF8.self) : self }
}
