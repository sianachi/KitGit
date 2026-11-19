import Foundation

struct RebasePlan: Identifiable, Codable {
    struct Entry: Identifiable, Codable {
        enum Action: String, CaseIterable, Codable {
            case pick, squash, fixup, drop
        }

        let id: String
        let subject: String
        var action: Action = .pick
    }

    let branch: String
    let head: String
    let base: String
    var entries: [Entry]
    var id: String { head }
}

extension Git {
    func rebasePlan(base: String) throws -> RebasePlan {
        let branch = try run(["symbolic-ref", "--quiet", "HEAD"]).droppingFinalNewline
        let head = try run(["rev-parse", "HEAD"]).droppingFinalNewline
        let ancestor = try run(["merge-base", base, head]).droppingFinalNewline
        guard ancestor == base, head != base else {
            throw GitFailure(message: "Choose an ancestor of the checked-out commit with at least one commit above it.")
        }
        let range = base + ".." + head
        guard try run(["rev-list", "--merges", range]).isEmpty else {
            throw GitFailure(message: "Choose a range without merge commits.")
        }
        let records = try paths(["log", "-z", "--reverse", "--format=%H%x1f%s", range])
        let entries = records.compactMap { record -> RebasePlan.Entry? in
            let parts = record.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return RebasePlan.Entry(id: String(parts[0]), subject: String(parts[1]))
        }
        return RebasePlan(branch: branch, head: head, base: base, entries: entries)
    }

    func runRebasePlan(_ plan: RebasePlan) throws {
        let clean = try run(["status", "--porcelain", "-z"]).isEmpty
        guard clean, try !operationInProgress(), try pendingStash() == nil else {
            throw GitFailure(message: "Finish any current operation and commit or stash working changes before rebasing.")
        }
        let current = try rebasePlan(base: plan.base)
        let kept = plan.entries.filter { $0.action != .drop }
        guard current.head == plan.head, current.branch == plan.branch,
              current.entries.map(\.id).sorted() == plan.entries.map(\.id).sorted(),
              kept.first?.action == .pick else {
            throw GitFailure(message: "Refresh the plan. The branch has changed or the first retained commit is set to squash or fixup.")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #if os(Windows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #else
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #endif
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = directory.appendingPathComponent("todo")
        let editor = directory.appendingPathComponent("editor")
        let instructions = plan.entries.map { $0.action.rawValue + " " + $0.id }.joined(separator: "\n") + "\n"
        try instructions.write(to: todo, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexec /bin/cat \"$KITGIT_REBASE_TODO\" > \"$1\"\n".write(to: editor, atomically: true, encoding: .utf8)
        #if os(Windows)
        let editorPath = editor.path.replacingOccurrences(of: "\\", with: "/")
        let todoPath = todo.path.replacingOccurrences(of: "\\", with: "/")
        let command = "sh "
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: editor.path)
        let editorPath = editor.path
        let todoPath = todo.path
        let command = ""
        #endif
        let sequenceEditor = command + "'" + editorPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try run(["-c", "rebase.autoStash=false", "-c", "rebase.autoSquash=false", "-c", "rebase.updateRefs=false",
                 "rebase", "--interactive", "--reapply-cherry-picks", "--no-rebase-merges", plan.base],
                environment: ["GIT_SEQUENCE_EDITOR": sequenceEditor, "KITGIT_REBASE_TODO": todoPath])
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct InteractiveRebaseView: View {
    @State var plan: RebasePlan
    let onStart: (RebasePlan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.headline)
            Text("Commits will replay top to bottom onto \(plan.base.prefix(7)). This rewrites commits on \(plan.branch.dropFirst("refs/heads/".count)).")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(plan.entries.indices, id: \.self) { index in
                        HStack(spacing: 8) {
                            Picker("Action", selection: $plan.entries[index].action) {
                                ForEach(RebasePlan.Entry.Action.allCases, id: \.self) {
                                    Text($0.rawValue.capitalized).tag($0)
                                }
                            }.labelsHidden().frame(width: 94)
                            Text(plan.entries[index].id.prefix(7)).font(.caption.monospaced())
                            Text(plan.entries[index].subject).lineLimit(1)
                            Spacer()
                            Button {
                                plan.entries.swapAt(index, index - 1)
                            } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("Move Up")
                            Button {
                                plan.entries.swapAt(index, index + 1)
                            } label: { Image(systemName: "chevron.down") }
                            .disabled(index + 1 == plan.entries.count).accessibilityLabel("Move Down")
                        }
                    }
                }
            }.frame(minHeight: 85, idealHeight: 210, maxHeight: 360)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rewrite Commits") {
                    onStart(plan)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(plan.entries.first { $0.action != .drop }?.action != .pick)
            }
        }.padding(20).frame(width: 620)
    }
}
#endif
