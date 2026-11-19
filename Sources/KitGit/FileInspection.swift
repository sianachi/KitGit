import Foundation

enum FileSnapshot: Equatable {
    case absent, tooLarge, unavailable
    case text(String)
    case binary(Data)

    private static let limit = 12 * 1024 * 1024

    init(data: Data) {
        if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
           let value = String(data: data, encoding: .utf16) {
            self = .text(value)
        } else if !data.contains(0), let value = String(data: data, encoding: .utf8) {
            self = .text(value)
        } else {
            self = .binary(data)
        }
    }

    static func blob(_ object: String?, git: Git) -> FileSnapshot {
        guard let object,
              let type = try? git.run(["cat-file", "-t", object]) else { return .absent }
        guard type == "blob\n",
              let rawSize = try? git.run(["cat-file", "-s", object]),
              let size = Int(rawSize.droppingFinalNewline) else { return .unavailable }
        guard size <= limit else { return .tooLarge }
        guard let data = try? git.bytes(["cat-file", "blob", object]) else { return .unavailable }
        return FileSnapshot(data: data)
    }

    static func worktree(_ path: String, git: Git) -> FileSnapshot {
        let url = git.root.appendingPathComponent(path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            return .absent
        }
        let root = git.root.resolvingSymlinksInPath().path
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == root ||
                url.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
            return .unavailable
        }
        if values.isSymbolicLink == true,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return .text(target)
        }
        guard values.isRegularFile == true else { return .unavailable }
        guard (values.fileSize ?? 0) <= limit else { return .tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            return data.count > limit ? .tooLarge : FileSnapshot(data: data)
        } catch {
            return .unavailable
        }
    }
}

struct FileInspection {
    let patch: Patch
    let before: FileSnapshot
    let after: FileSnapshot
    let beforeTitle: String
    let afterTitle: String
    let hunks: [NumberedHunk]

    struct NumberedHunk: Identifiable {
        struct Line: Identifiable {
            let source: Patch.Line
            let old: Int?
            let new: Int?
            var id: Int { source.id }
        }

        struct Pair: Identifiable {
            let left: Line?
            let right: Line?
            var id: Int { left?.id ?? right?.id ?? 0 }
        }

        let id: Int
        let header: String
        let lines: [Line]
        let pairs: [Pair]
        let changes: [Int: Set<Int>]

        init(_ hunk: Patch.Hunk) {
            id = hunk.id
            header = hunk.header
            let ranges = header.split(separator: " ").dropFirst().prefix(2)
            let starts = ranges.compactMap { Int($0.dropFirst().prefix { $0 != "," }) }
            var old = starts.first ?? 0
            var new = starts.last ?? 0
            lines = hunk.lines.map { source in
                let from = source.text.hasPrefix(" ") || source.text.hasPrefix("-")
                let to = source.text.hasPrefix(" ") || source.text.hasPrefix("+")
                let line = Line(source: source, old: from ? old : nil, new: to ? new : nil)
                if from { old += 1 }
                if to { new += 1 }
                return line
            }
            var aligned: [Pair] = []
            var removed: [Line] = []
            var added: [Line] = []
            func flush() {
                for index in 0..<max(removed.count, added.count) {
                    aligned.append(Pair(left: index < removed.count ? removed[index] : nil,
                                        right: index < added.count ? added[index] : nil))
                }
                removed.removeAll(keepingCapacity: true)
                added.removeAll(keepingCapacity: true)
            }
            var previousSide: Character?
            for line in lines {
                switch line.source.text.first {
                case "-": removed.append(line)
                case "+": added.append(line)
                case "\\":
                    flush()
                    aligned.append(previousSide == "+" ? Pair(left: nil, right: line) : Pair(left: line, right: nil))
                default:
                    flush()
                    aligned.append(Pair(left: line, right: line))
                }
                previousSide = line.source.text.first
            }
            flush()
            pairs = aligned
            var map: [Int: Set<Int>] = [:]
            for pair in aligned {
                guard let left = pair.left?.source, let right = pair.right?.source,
                      left.text.hasPrefix("-"), right.text.hasPrefix("+") else { continue }
                let change = InlineChange(old: String(left.text.dropFirst()), new: String(right.text.dropFirst()))
                map[left.id] = change.old
                map[right.id] = change.new
            }
            changes = map
        }
    }

    init(patch: Patch, before: FileSnapshot, after: FileSnapshot, beforeTitle: String, afterTitle: String) {
        self.patch = patch
        self.before = before
        self.after = after
        self.beforeTitle = beforeTitle
        self.afterTitle = afterTitle
        hunks = patch.hunks.map(NumberedHunk.init)
    }
}

extension Git {
    func inspectFile(_ path: String, staged: Bool) throws -> FileInspection {
        let patch = Patch(try diff(path, staged: staged))
        let stagedFile = FileSnapshot.blob(":" + path, git: self)
        return FileInspection(patch: patch,
                              before: staged ? .blob("HEAD:" + path, git: self) : stagedFile,
                              after: staged ? stagedFile : .worktree(path, git: self),
                              beforeTitle: staged ? "HEAD" : "Index", afterTitle: staged ? "Index" : "Working Copy")
    }

    func inspectFile(_ path: String, at commit: Commit) throws -> FileInspection {
        let patch = Patch(try run(["--literal-pathspecs", "show", "--format=", "--patch", "--first-parent",
                                   "--diff-merges=first-parent", "--no-renames", "--no-ext-diff", "--no-textconv",
                                   commit.id, "--", path]))
        return FileInspection(patch: patch, before: .blob(commit.parents.first.map { $0 + ":" + path }, git: self),
                              after: .blob(commit.id + ":" + path, git: self),
                              beforeTitle: "Parent", afterTitle: String(commit.id.prefix(7)))
    }
}
