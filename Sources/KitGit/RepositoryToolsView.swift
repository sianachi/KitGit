import SwiftUI

struct RepositoryToolsView: View {
    @ObservedObject var model: Workspace
    let repo: Repository
    @State private var pullRequests = false
    @State private var worktreesExpanded = true
    @State private var stashesExpanded = true
    @State private var tagsExpanded = false
    @State private var addTree = false
    @State private var newBranch = true
    @State private var branch = ""
    @State private var createStash = false
    @State private var stashMessage = ""
    @State private var includeUntracked = true
    @State private var removeTree: Worktree?
    @State private var dropStash: Stash?

    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup(isExpanded: $worktreesExpanded) {
                ForEach(repo.worktrees) { tree in
                    Button { model.open(tree.url) } label: {
                        row(tree.name, detail: tree.branch ?? (tree.bare ? "Bare" : "Detached HEAD"),
                            icon: tree.locked ? "lock" : tree.missing ? "exclamationmark.triangle" : "folder",
                            selected: tree.url.resolvingSymlinksInPath() == repo.root.resolvingSymlinksInPath())
                    }
                    .buttonStyle(.plain)
                    .disabled(tree.bare || tree.missing)
                    .help(tree.id)
                    .contextMenu {
                        Button("Open in Tab") { model.open(tree.url) }
                        if !tree.main {
                            Button(tree.locked ? "Unlock Worktree" : "Lock Worktree") {
                                model.change { try $0.run(["worktree", tree.locked ? "unlock" : "lock", "--", tree.id]) }
                            }
                            Button("Remove Worktree…", role: .destructive) { removeTree = tree }
                                .disabled(tree.locked || tree.url.resolvingSymlinksInPath() == repo.root.resolvingSymlinksInPath())
                        }
                    }
                }
            } label: {
                sectionLabel("Worktrees", icon: "point.3.connected.trianglepath.dotted", count: repo.worktrees.count) {
                    branch = ""
                    newBranch = true
                    addTree = true
                }
                .disabled(repo.graph.rows.isEmpty)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            Divider()
            DisclosureGroup(isExpanded: $stashesExpanded) {
                ForEach(repo.stashes) { stash in
                    Button { model.selectStash(stash) } label: {
                        row(stash.message, detail: stash.id, icon: "tray",
                            selected: model.stashPreview?.hash == stash.hash)
                    }
                    .buttonStyle(.plain)
                    .help(stash.message)
                    .contextMenu {
                        Button("Inspect Stash") { model.selectStash(stash) }
                        Button("Apply Stash") { restore(stash, index: false, remove: false) }.disabled(blocked)
                        Button("Apply and Restore Staging") { restore(stash, index: true, remove: false) }.disabled(blocked)
                        Button("Pop Stash") { restore(stash, index: true, remove: true) }.disabled(blocked)
                        Divider()
                        Button("Drop Stash…", role: .destructive) { dropStash = stash }
                    }
                }
            } label: {
                sectionLabel("Stashes", icon: "tray.full", count: repo.stashes.count) {
                    stashMessage = ""
                    includeUntracked = true
                    createStash = true
                }
                .disabled(blocked || !repo.dirty)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            Divider()
            if !repo.gitHubRemotes.isEmpty {
                Button { pullRequests = true } label: {
                    HStack {
                        Label("Pull Requests", systemImage: "arrow.triangle.pull")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 11).padding(.vertical, 10)
                Divider()
            }
            DisclosureGroup(isExpanded: $tagsExpanded) {
                ForEach(repo.tags, id: \.self) { tag in
                    Button {
                        model.selectRef("refs/tags/" + tag)
                    } label: {
                        Label(tag, systemImage: "tag")
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(5)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tag)
                }
            } label: {
                HStack {
                    Label("Tags", systemImage: "tag").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(repo.tags.count, format: .number).monospacedDigit().foregroundStyle(.tint)
                }.padding(.vertical, 5)
            }.padding(.horizontal, 11).padding(.vertical, 5)
            Divider()
        }
        .sheet(isPresented: $pullRequests) {
            PullRequestsView(repo: repo) { model.refresh() }
        }
        .sheet(isPresented: $addTree) { worktreeSheet }
        .sheet(isPresented: $createStash) { stashSheet }
        .alert("Remove worktree?", isPresented: Binding(get: { removeTree != nil }, set: {
            if !$0 { removeTree = nil }
        }), presenting: removeTree) { tree in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { model.removeWorktree(tree) }
        } message: { tree in
            Text("Remove the checkout at \(tree.id). The branch will still be available in Git.")
        }
        .alert("Drop stash?", isPresented: Binding(get: { dropStash != nil }, set: {
            if !$0 { dropStash = nil }
        }), presenting: dropStash) { stash in
            Button("Cancel", role: .cancel) {}
            Button("Drop", role: .destructive) { model.change { try $0.dropStash(stash) } }
        } message: { stash in
            Text("Delete the saved changes in \(stash.message).")
        }
    }

    private var blocked: Bool { repo.operationInProgress || !repo.conflicts.isEmpty }

    private var availableBranches: [Branch] {
        let checkedOut = Set(repo.worktrees.compactMap(\.branch))
        return repo.branches.filter { !$0.remote && !checkedOut.contains($0.name) }
    }

    private var worktreeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.headline)
            Picker("Branch", selection: $newBranch) {
                Text("Create Branch from HEAD").tag(true)
                Text("Use Existing Branch").tag(false)
            }.onChange(of: newBranch) { _, create in
                branch = create ? "" : availableBranches.first?.name ?? ""
            }
            if newBranch {
                TextField("Branch name", text: $branch)
            } else {
                Picker("Branch to check out", selection: $branch) {
                    if availableBranches.isEmpty { Text("No unchecked-out local branches").tag("") }
                    ForEach(availableBranches) { Text($0.name).tag($0.name) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { addTree = false }.keyboardShortcut(.cancelAction)
                Button("Choose Location…") {
                    worktreeRequest = (branch, newBranch)
                    addTree = false
                }.keyboardShortcut(.defaultAction).disabled(branch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 400)
        .onDisappear {
            if let request = worktreeRequest {
                worktreeRequest = nil
                Task { model.addWorktree(branch: request.branch, newBranch: request.new) }
            }
        }
    }

    @State private var worktreeRequest: (branch: String, new: Bool)?

    private var stashSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stash Changes").font(.headline)
            TextField("Message (optional)", text: $stashMessage)
            Toggle("Include untracked files", isOn: $includeUntracked)
            HStack {
                Spacer()
                Button("Cancel") { createStash = false }.keyboardShortcut(.cancelAction)
                Button("Stash") {
                    let message = stashMessage, include = includeUntracked
                    createStash = false
                    model.change { try $0.createStash(message: message, includeUntracked: include) }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 370)
    }

    private func restore(_ stash: Stash, index: Bool, remove: Bool) {
        model.change { try $0.applyStash(stash, index: index, remove: remove) }
    }

    private func sectionLabel(_ name: String, icon: String, count: Int,
                              add: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(count, format: .number).monospacedDigit().foregroundStyle(.tint)
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless).accessibilityLabel(name == "Worktrees" ? "Add Worktree" : "Create Stash")
        }.padding(.vertical, 5)
    }

    private func row(_ name: String, detail: String, icon: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(5)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}
