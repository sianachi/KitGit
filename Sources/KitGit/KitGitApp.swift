import SwiftUI

@main
struct KitGitApp: App {
    @StateObject private var model = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(.dark)
                .task { model.reopen() }
        }
        .defaultSize(width: 1400, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                    .disabled(model.busy)
                Button("Close Repository Tab") {
                    if let root = model.repo?.root { model.close(root) }
                }.keyboardShortcut("w").disabled(model.busy || model.repo == nil)
            }
            CommandMenu("Repository") {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.busy || model.repo == nil)
            }
        }
    }
}

private let base = Color(red: 0.107, green: 0.118, blue: 0.136)
private let panel = Color(red: 0.151, green: 0.160, blue: 0.192)
private let chrome = Color(red: 0.197, green: 0.211, blue: 0.247)
private let rule = Color.white.opacity(0.09)
private let accent = Color(red: 0.51, green: 0.75, blue: 1)
private let added = Color(red: 0.45, green: 0.85, blue: 0.67)
private let removed = Color(red: 1, green: 0.57, blue: 0.59)
private let laneColors: [Color] = [Color(red: 0.10, green: 0.70, blue: 0.82), .blue, .purple, .mint, .orange, .pink]

struct ContentView: View {
    @ObservedObject var model: Workspace
    @State private var expandFile = false
    @State private var browseFiles = false
    @State private var repositoryFiles: [String] = []
    @State private var searchPrompt = false
    @State private var searchQuery = ""
    @State private var addRemote = false
    @State private var remoteName = ""
    @State private var remoteURL = ""
    @State private var clonePrompt = false
    @State private var cloneSource = ""
    @State private var branchPrompt = false
    @State private var branchName = ""
    @State private var mergeTarget: Branch?
    @State private var abortMerge = false
    @State private var deleteBranch: Branch?
    @State private var tagCommit: Commit?
    @State private var tagName = ""
    @State private var replay: (command: String, commit: Commit)?
    @State private var abortReplay = false
    @State private var interactivePlan: RebasePlan?
    @State private var branchFilter = ""
    @State private var localExpanded = true
    @State private var remotesExpanded = false
    @State private var rebaseTarget: Branch?
    @State private var rebaseConfirmation = false
    @State private var rebaseAction: String?
    @State private var actionConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty { repositoryTabs }
            toolbar
            Divider()
            if let repo = model.repo {
                if repo.operationInProgress || repo.savedChanges { operationBar(repo) }
                HSplitView {
                    sidebar(repo).frame(minWidth: 155, idealWidth: 200, maxWidth: 235)
                    mainPane(repo).frame(minWidth: 385, idealWidth: 820)
                    inspector(repo).frame(minWidth: 330, idealWidth: 365, maxWidth: 455)
                }
                .disabled(model.busy)
                Divider()
                footer(repo)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(accent)
                    Text("Open a Git repository").font(.title2.weight(.semibold))
                    Button("Choose Folder…", action: model.chooseFolder)
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(model.busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(base)
        .tint(accent)
        .sheet(isPresented: $expandFile) {
            VStack(spacing: 0) {
                HStack {
                    Text(model.file?.path ?? model.commitFile ?? "File")
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Done") { expandFile = false }.keyboardShortcut(.cancelAction)
                }.padding(12)
                Divider()
                if let inspection = model.inspection, let file = model.file {
                    diffEditor(inspection, file: file, expanded: true)
                } else if let inspection = model.inspection, let path = model.commitFile {
                    FileInspectionView(path: path, inspection: inspection, canStage: false, selection: .constant([]))
                }
            }.frame(minWidth: 920, idealWidth: 1120, minHeight: 520, idealHeight: 690)
        }
        .sheet(isPresented: $browseFiles) {
            RepositoryFilesView(paths: repositoryFiles) { path in
                browseFiles = false
                model.selectFile(.init(path: path, staged: false))
            }
        }
        .sheet(item: $interactivePlan) { plan in
            InteractiveRebaseView(plan: plan) { updated in
                model.change(conflictsExpected: true) { try $0.runRebasePlan(updated) }
            }
        }
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: {
            if !$0 { model.error = nil }
        }), actions: { Button("OK") { model.error = nil } }, message: {
            Text(model.error ?? "")
        })
        .alert("Search Commits", isPresented: $searchPrompt) {
            TextField("Commit message or hash", text: $searchQuery)
            Button("Cancel", role: .cancel) {}
            Button("Search") { model.searchCommits(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        .alert("Add Remote", isPresented: $addRemote) {
            TextField("Name", text: $remoteName)
            TextField("Repository URL or path", text: $remoteURL)
            Button("Cancel", role: .cancel) {}
            Button("Add Remote") {
                let name = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !url.isEmpty else { return }
                model.change { try $0.run(["remote", "add", "--", name, url]) }
            }
        }
        .alert("Clone Repository", isPresented: $clonePrompt) {
            TextField("Repository URL or path", text: $cloneSource)
            Button("Cancel", role: .cancel) {}
            Button("Choose Location…") {
                let source = cloneSource.trimmingCharacters(in: .whitespacesAndNewlines)
                if !source.isEmpty { Task { model.createRepository(clone: source) } }
            }
        }
        .alert("Create Branch", isPresented: $branchPrompt) {
            TextField("Branch name", text: $branchName)
            Button("Cancel", role: .cancel) {}
            Button("Create and Check Out") {
                let name = branchName
                guard !name.isEmpty else { return }
                model.change { git in
                    try git.run(["check-ref-format", "--branch", name])
                    try git.run(["switch", "-c", name])
                }
            }
        }
        .alert("Merge Branch?", isPresented: Binding(get: { mergeTarget != nil }, set: {
            if !$0 { mergeTarget = nil }
        }), presenting: mergeTarget) { branch in
            Button("Cancel", role: .cancel) {}
            Button("Merge") {
                model.change(conflictsExpected: true) { try $0.run(["merge", "--no-edit", "--", branch.id]) }
            }
        } message: { branch in
            Text("Merge \(branch.name) into \(model.repo?.branch ?? "").")
        }
        .alert("Abort merge?", isPresented: $abortMerge) {
            Button("Cancel", role: .cancel) {}
            Button("Abort Merge", role: .destructive) { model.change { try $0.run(["merge", "--abort"]) } }
        } message: {
            Text("Git will discard conflict resolutions made during this merge.")
        }
        .alert("Delete local branch?", isPresented: Binding(get: { deleteBranch != nil }, set: {
            if !$0 { deleteBranch = nil }
        }), presenting: deleteBranch) { branch in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.change { try $0.run(["branch", "--delete", "--", branch.name]) }
            }
        } message: { branch in
            Text("Delete the local branch \(branch.name). Git will refuse if the branch has unmerged commits.")
        }
        .alert("Create Tag", isPresented: Binding(get: { tagCommit != nil }, set: {
            if !$0 { tagCommit = nil }
        }), presenting: tagCommit) { commit in
            TextField("Tag name", text: $tagName)
            Button("Cancel", role: .cancel) {}
            Button("Create Tag") {
                let name = tagName
                guard !name.isEmpty else { return }
                model.change { try $0.run(["tag", "--", name, commit.id]) }
            }
        }
        .alert("Apply Commit Operation?", isPresented: Binding(get: { replay != nil }, set: {
            if !$0 { replay = nil }
        }), presenting: replay) { action in
            Button("Cancel", role: .cancel) {}
            Button(action.command == "revert" ? "Revert" : "Cherry-pick") {
                model.change(conflictsExpected: true) {
                    try $0.run([action.command, "--no-edit", action.commit.id])
                }
            }
        } message: { action in
            Text("\(action.command == "revert" ? "Revert" : "Cherry-pick") \(action.commit.id.prefix(7)) on \(model.repo?.branch ?? "").")
        }
        .alert("Abort commit operation?", isPresented: $abortReplay) {
            Button("Cancel", role: .cancel) {}
            Button("Abort", role: .destructive) {
                if let op = model.repo?.replayOperation { model.change { try $0.run([op, "--abort"]) } }
            }
        } message: {
            Text("Git will discard conflict resolutions made during this operation.")
        }
        .alert("Rebase onto \(rebaseTarget?.name ?? "")?", isPresented: $rebaseConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(model.repo?.dirty == true ? "Stash and Rebase" : "Rebase") {
                startRebase(stash: model.repo?.dirty == true)
            }
        } message: {
            let summary = "Git will replay commits from \(model.repo?.branch ?? "") onto \(rebaseTarget?.name ?? "")."
            let stash = " KitGit will first stash staged, unstaged, and untracked changes. It will try to restore them when the rebase ends and keep a copy in Git's stash list."
            Text(summary + (model.repo?.dirty == true ? stash : ""))
        }
        .alert(rebaseAction == "--skip" ? "Skip this commit?" : "Abort the rebase?", isPresented: $actionConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(rebaseAction == "--skip" ? "Skip Commit" : "Abort Rebase", role: .destructive) {
                if let action = rebaseAction { model.change(conflictsExpected: true) { try $0.finishRebase(action) } }
            }
        } message: {
            Text(rebaseAction == "--skip" ? "Git will leave this commit out of the rebased branch."
                 : "Git will reset the branch to where it was before rebasing and discard current conflict resolutions.")
        }
    }

    private var repositoryTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.self) { url in
                    HStack(spacing: 2) {
                        Button { model.open(url) } label: {
                            Label(url.lastPathComponent, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 12, weight: model.repo?.root == url ? .semibold : .medium))
                                .lineLimit(1).padding(.horizontal, 8).frame(height: 31)
                        }.buttonStyle(.plain).help(url.path)
                        Button { model.close(url) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        }.buttonStyle(.borderless).padding(.trailing, 6)
                            .accessibilityLabel("Close " + url.lastPathComponent)
                    }
                    .foregroundStyle(model.repo?.root == url ? .primary : .secondary)
                    .background(model.repo?.root == url ? chrome : panel, in: RoundedRectangle(cornerRadius: 5))
                }
                Button(action: model.chooseFolder) {
                    Image(systemName: "plus").frame(width: 27, height: 28)
                }.buttonStyle(.borderless).accessibilityLabel("Open Repository in New Tab")
            }.padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: 34)
        .background(panel)
        .disabled(model.busy)
    }

    private var toolbar: some View {
        HStack(spacing: 11) {
            if let repo = model.repo {
                toolbarField("Repository", value: repo.root.lastPathComponent).help(repo.root.path)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                toolbarField("Branch", value: repo.branch.isEmpty ? "Detached HEAD" : repo.branch)
            } else {
                Text("KitGit").font(.headline)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Running Git") }
            Menu {
                Button("Open Repository…", action: model.chooseFolder)
                Button("Clone Repository…") { cloneSource = ""; clonePrompt = true }
                Button("Initialize Repository…") { Task { model.createRepository() } }
                if model.repo != nil {
                    Divider()
                    Button("Add Remote…") { remoteName = "origin"; remoteURL = ""; addRemote = true }
                }
            } label: { Label("Repository", systemImage: "folder") }
            .fixedSize()
            if let repo = model.repo {
                Button { model.change { try $0.run(["fetch", "--all"]) } } label: {
                    Label("Fetch", systemImage: "arrow.down.circle")
                }.disabled(repo.remotes.isEmpty)
                Button { model.change { try $0.run(["pull", "--ff-only", "--no-rebase"]) } } label: {
                    Label("Pull", systemImage: "arrow.down")
                }.help("Pull from the upstream branch using a fast-forward")
                    .disabled(repo.remotes.isEmpty || repo.branch.isEmpty || repo.operationInProgress)
                Menu {
                    ForEach(repo.remotes, id: \.self) { remote in
                        Button("Push \(repo.branch) to \(remote)") {
                            let branch = repo.branch
                            model.change { try $0.push(branch: branch, to: remote) }
                        }
                    }
                } label: { Label("Push", systemImage: "arrow.up") }
                .fixedSize().disabled(repo.remotes.isEmpty || repo.branch.isEmpty || repo.operationInProgress)
                Button { branchName = ""; branchPrompt = true } label: {
                    Label("Branch", systemImage: "arrow.triangle.branch")
                }.disabled(repo.graph.rows.isEmpty || repo.operationInProgress || !repo.conflicts.isEmpty)
            }
            Button { searchQuery = ""; searchPrompt = true } label: {
                Label("Search", systemImage: "magnifyingglass")
            }.help("Search commit messages and hashes")
                .disabled(model.repo?.graph.rows.isEmpty != false)
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.repo == nil)
        }
        .buttonStyle(.bordered)
        .disabled(model.busy)
        .padding(.horizontal, 16).frame(height: 53)
        .background(chrome)
    }

    private func toolbarField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold)).lineLimit(1)
        }
        .frame(minWidth: 85, alignment: .leading)
    }

    private func sidebar(_ repo: Repository) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Label("Branches", systemImage: "arrow.triangle.branch").font(.headline)
                TextField("Filter branches", text: $branchFilter)
                    .textFieldStyle(.roundedBorder)
            }.padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    branchGroup(repo.branches.filter { !$0.remote }, name: "Local", icon: "laptopcomputer",
                                expanded: $localExpanded, repo: repo)
                    Divider()
                    branchGroup(repo.branches.filter(\.remote), name: "Remotes", icon: "cloud",
                                expanded: $remotesExpanded, repo: repo)
                    Divider()
                    RepositoryToolsView(model: model, repo: repo)
                        .id(repo.root)
                }
            }
        }
        .background(panel)
    }

    private func branchGroup(_ allBranches: [Branch], name: String, icon: String,
                             expanded: Binding<Bool>, repo: Repository) -> some View {
        let branches = allBranches.filter { branchFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(branchFilter) }
        let filtering = !branchFilter.isEmpty
        return DisclosureGroup(isExpanded: filtering ? .constant(true) : expanded) {
            if branches.isEmpty {
                Text(filtering ? "No matches" : "No branches").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
            ForEach(branches) { branch in
                let current = branch.id == "refs/heads/" + repo.branch
                HStack(spacing: 7) {
                    Image(systemName: current ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        .foregroundStyle(current ? accent : .secondary)
                    Text(branch.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: current ? .semibold : .regular))
                .padding(.horizontal, 7).frame(height: 28)
                .background(current ? accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .help(branch.name)
                .contextMenu {
                    if !branch.remote {
                        Button("Check Out \(branch.name)") {
                            model.change { try $0.run(["switch", "--", branch.name]) }
                        }
                        .disabled(current || repo.operationInProgress || !repo.conflicts.isEmpty)
                        Button("Delete Local Branch…", role: .destructive) { deleteBranch = branch }
                            .disabled(current || repo.operationInProgress ||
                                      repo.worktrees.contains { $0.branch == branch.name })
                    } else {
                        Button("Check Out as Tracking Branch") {
                            model.change { try $0.run(["switch", "--track", "--", branch.name]) }
                        }.disabled(repo.operationInProgress || !repo.conflicts.isEmpty)
                    }
                    Button("Merge \(branch.name) into Current Branch…") { mergeTarget = branch }
                        .disabled(current || repo.branch.isEmpty || repo.operationInProgress || repo.dirty)
                    Button("Rebase Current Branch onto \(branch.name)…") {
                        rebaseTarget = branch
                        rebaseConfirmation = true
                    }
                    .disabled(current || repo.branch.isEmpty || repo.operationInProgress || repo.savedChanges || !repo.conflicts.isEmpty)
                }
            }
        } label: {
            HStack {
                Label(name, systemImage: icon).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(branches.count, format: .number).monospacedDigit().foregroundStyle(accent)
            }.padding(.vertical, 5)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
    }

    private let refWidth: CGFloat = 132

    private func graph(_ repo: Repository) -> some View {
        GeometryReader { pane in
            let laneWidth = max(108, CGFloat(repo.graph.width * 18 + 18))
            let messageWidth = max(200, pane.size.width - refWidth - laneWidth)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        Button { model.clearSelection() } label: {
                            HStack(spacing: 0) {
                                Color.clear.frame(width: refWidth)
                                Image(systemName: "circle.dotted").foregroundStyle(accent)
                                    .padding(.leading, 8).frame(width: laneWidth, alignment: .leading)
                                Text("Working Directory").fontWeight(.semibold).padding(.leading, 8)
                                Spacer()
                                Text("\(repo.staged.count + repo.unstaged.count + repo.conflicts.count) changes")
                                    .foregroundStyle(.secondary).padding(.trailing, 10)
                            }
                            .frame(width: refWidth + laneWidth + messageWidth, height: 31)
                            .background(model.commit == nil && model.stashPreview == nil && model.history == nil && model.attribution == nil ? accent.opacity(0.13) : panel)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        ForEach(repo.graph.rows) { row in
                            graphRow(row, laneWidth: laneWidth, messageWidth: messageWidth)
                        }
                        if repo.graph.rows.isEmpty {
                            Text("No commits yet").foregroundStyle(.secondary).padding(12)
                        }
                        if repo.canLoadMore {
                            Button("Load More Commits") { model.refresh(loadMore: true) }.padding()
                        }
                    } header: {
                        HStack(spacing: 0) {
                            graphHeading("Branch / Tag", width: refWidth)
                            graphHeading("Graph", width: laneWidth)
                            graphHeading("Commit Message", width: messageWidth)
                        }
                        .background(panel)
                        .overlay(alignment: .bottom) { rule.frame(height: 1) }
                    }
                }
            }
        }
    }

    private func graphHeading(_ label: String, width: CGFloat) -> some View {
        Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 9).frame(width: width, height: 27, alignment: .leading)
            .overlay(alignment: .trailing) { rule.frame(width: 1) }
    }

    private func graphRow(_ row: GraphRow, laneWidth: CGFloat, messageWidth: CGFloat) -> some View {
        let color = laneColors[row.color % laneColors.count]
        let selected = model.commit?.id == row.id
        let refs = row.commit.refs.replacingOccurrences(of: "HEAD -> ", with: "")
        return Button { model.selectCommit(row.commit) } label: {
            HStack(spacing: 0) {
                HStack {
                    if !refs.isEmpty {
                        Label(refs, systemImage: row.commit.refs.hasPrefix("HEAD") ? "checkmark" : "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(color.opacity(0.27), in: RoundedRectangle(cornerRadius: 3))
                            .help(row.commit.refs)
                    }
                }
                .padding(.leading, 8)
                .frame(width: refWidth, alignment: .leading)
                lanes(row, width: laneWidth)
                    .background(color.opacity(selected ? 0.24 : 0.075))
                HStack(spacing: 10) {
                    Text(row.commit.subject).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(row.commit.date)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 9).frame(width: messageWidth, alignment: .leading)
                .overlay(alignment: .leading) { color.opacity(0.6).frame(width: 2) }
            }
            .frame(height: 28)
            .background(selected ? accent.opacity(0.21) : .clear)
            .overlay(alignment: .bottom) { rule.frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(row.commit.subject)\n\(row.commit.author)")
        .contextMenu {
            if let repo = model.repo {
                Button("Interactively Rebase Commits Above Here…") {
                    model.prepareRebase(onto: row.commit) { interactivePlan = $0 }
                }.disabled(repo.operationInProgress || repo.dirty || repo.branch.isEmpty || repo.savedChanges)
                Button("Create Tag Here…") { tagName = ""; tagCommit = row.commit }
                Button("Cherry-pick Commit…") { replay = ("cherry-pick", row.commit) }
                    .disabled(repo.operationInProgress || repo.dirty || repo.branch.isEmpty || row.commit.parents.count > 1)
                Button("Revert Commit…") { replay = ("revert", row.commit) }
                    .disabled(repo.operationInProgress || repo.dirty || repo.branch.isEmpty || row.commit.parents.count > 1)
                Divider()
            }
            Button("Copy Commit Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.id, forType: .string)
            }
        }
    }

    private func lanes(_ row: GraphRow, width: CGFloat) -> some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { CGFloat(lane * 18 + 14) }
            for edge in row.above {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: 0))
                path.addLine(to: CGPoint(x: x(edge.to), y: mid))
                context.stroke(path, with: .color(laneColors[edge.color % laneColors.count]), lineWidth: 1.5)
            }
            for edge in row.below {
                var path = Path()
                path.move(to: CGPoint(x: x(edge.from), y: mid))
                path.addQuadCurve(to: CGPoint(x: x(edge.to), y: size.height),
                                  control: CGPoint(x: x(edge.to), y: mid))
                context.stroke(path, with: .color(laneColors[edge.color % laneColors.count]), lineWidth: 1.5)
            }
            let color = laneColors[row.color % laneColors.count]
            if !row.commit.refs.isEmpty {
                var connector = Path()
                connector.move(to: CGPoint(x: 0, y: mid))
                connector.addLine(to: CGPoint(x: x(row.lane), y: mid))
                context.stroke(connector, with: .color(color), lineWidth: 1.5)
            }
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - 5, y: mid - 5, width: 10, height: 10))
            context.fill(dot, with: .color(row.commit.parents.count > 1 ? color : base))
            context.stroke(dot, with: .color(color), lineWidth: 2)
        }
        .frame(width: width, height: 28)
        .accessibilityHidden(true)
    }

    private func footer(_ repo: Repository) -> some View {
        HStack {
            Text(repo.root.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(repo.staged.count) staged  /  \(repo.unstaged.count) unstaged")
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 26).background(panel)
    }

    private func operationBar(_ repo: Repository) -> some View {
        HStack {
            Label(repo.rebasing ? "Rebase in progress" : repo.merging ? "Merge in progress" :
                  repo.replayOperation == "revert" ? "Revert in progress" :
                  repo.replayOperation == "cherry-pick" ? "Cherry-pick in progress" : "Saved changes awaiting restore",
                  systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            Spacer()
            if repo.rebasing {
                Button("Abort…") { confirmAction("--abort") }
                Button("Skip Commit…") { confirmAction("--skip") }
                Button("Continue Rebase") { model.change(conflictsExpected: true) { try $0.finishRebase("--continue") } }
                    .buttonStyle(.borderedProminent).disabled(!repo.conflicts.isEmpty)
            } else if repo.merging {
                Button("Abort Merge…") { abortMerge = true }
                Button("Finish Merge") { model.change { try $0.run(["commit", "--no-edit"]) } }
                    .buttonStyle(.borderedProminent).disabled(!repo.conflicts.isEmpty)
            } else if let command = repo.replayOperation {
                Button("Abort…") { abortReplay = true }
                Button("Continue") { model.change(conflictsExpected: true) { try $0.run([command, "--continue"]) } }
                    .buttonStyle(.borderedProminent).disabled(!repo.conflicts.isEmpty)
            } else {
                Button("Keep in Stash") { model.change { try $0.keepStash() } }
                Button("Try Restore") { model.change { try $0.restoreStash() } }
                    .disabled(!repo.conflicts.isEmpty)
            }
        }
        .font(.system(size: 12, weight: .medium)).padding(10)
        .background(Color.orange.opacity(0.09)).disabled(model.busy)
    }

    private func confirmAction(_ action: String) {
        rebaseAction = action
        actionConfirmation = true
    }

    private func startRebase(stash: Bool) {
        guard let ref = rebaseTarget?.id, let branch = model.repo?.branch else { return }
        model.change(conflictsExpected: true) { git in
            guard try git.run(["symbolic-ref", "--quiet", "--short", "HEAD"]).droppingFinalNewline == branch else {
                throw GitFailure(message: "The checked-out branch changed. Review it before rebasing.")
            }
            try git.rebase(onto: ref, stash: stash)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
    }

    private func inspector(_ repo: Repository) -> some View {
        VStack(spacing: 0) {
            HStack {
                if let commit = model.commit {
                    Label(String(commit.id.prefix(7)), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                } else if let stash = model.stashPreview {
                    sectionTitle(stash.id, icon: "tray")
                } else if model.history != nil || model.attribution != nil {
                    Text(model.historyTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                } else {
                    sectionTitle("Working Directory", icon: "square.and.pencil")
                }
                Spacer()
                if model.commit != nil || model.stashPreview != nil || model.history != nil || model.attribution != nil {
                    Button("Working Changes") { model.clearSelection() }.buttonStyle(.borderless)
                }
                Button("Browse Files") {
                    model.listFiles { paths in
                        repositoryFiles = paths
                        browseFiles = true
                    }
                }.buttonStyle(.borderless)

            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            if let commit = model.commit {
                commitInspector(commit)
            } else if let stash = model.stashPreview {
                Text(stash.message).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                Divider()
                code(model.stashDiff)
            } else if let results = model.history {
                if results.isEmpty {
                    ContentUnavailableView("No commits found", systemImage: "magnifyingglass")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { commit in
                                Button { model.selectCommit(commit) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(commit.subject).lineLimit(1)
                                        Text("\(commit.id.prefix(7))  \(commit.author)  \(commit.date)")
                                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).overlay(alignment: .bottom) { rule.frame(height: 1) }
                            }
                        }
                    }
                }
            } else if let attribution = model.attribution {
                code(attribution)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !repo.conflicts.isEmpty {
                            Text("Conflicts").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            ForEach(repo.conflicts, id: \.self) { path in
                                Button { model.selectConflict(path) } label: {
                                    Label(path, systemImage: "exclamationmark.triangle")
                                        .lineLimit(1).padding(5).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(model.conflict?.path == path ? accent.opacity(0.15) : .clear)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        fileGroup("Unstaged", paths: repo.unstaged, staged: false)
                        fileGroup("Staged", paths: repo.staged, staged: true)
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !repo.operationInProgress && repo.conflicts.isEmpty {
                    Divider()
                    HStack(alignment: .bottom) {
                        ZStack(alignment: .topLeading) {
                            if model.message.isEmpty {
                                Text("Commit message").foregroundStyle(.secondary).padding(7).allowsHitTesting(false)
                            }
                            TextEditor(text: $model.message).scrollContentBackground(.hidden)
                                .padding(3).accessibilityLabel("Commit message")
                        }
                        .frame(height: 60)
                        .background(base, in: RoundedRectangle(cornerRadius: 5))
                        Button("Commit") { model.makeCommit() }.buttonStyle(.borderedProminent)
                            .disabled(repo.staged.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(10)
                }
            }
        }
        .background(panel)
    }

    private func commitInspector(_ commit: Commit) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    Text(model.commitDetail)
                        .font(.system(size: 15, weight: .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(base, in: RoundedRectangle(cornerRadius: 5))
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 29)).foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.author).fontWeight(.medium).lineLimit(1)
                            Text(commit.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !commit.parents.isEmpty {
                            Text("Parent " + commit.parents.map { String($0.prefix(7)) }.joined(separator: ", "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Divider()
                    Label("Changed files (\(model.commitFiles.count))", systemImage: "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(model.commitFiles, id: \.self) { path in
                        Button { model.selectCommitFile(path) } label: {
                            Label(path, systemImage: "doc.text")
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6).background(model.commitFile == path ? accent.opacity(0.16) : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(path)
                        .contextMenu {
                            Button("File History") { model.showFileHistory(path, at: commit.id) }
                            Button("Blame at This Commit") { model.blameFile(path, at: commit.id) }
                        }
                    }
                }.padding(11)
            }

        }.frame(maxHeight: .infinity)
    }

    private func fileGroup(_ title: String, paths: [String], staged: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) (\(paths.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(paths, id: \.self) { path in
                let item = Workspace.File(path: path, staged: staged)
                HStack(spacing: 4) {
                    Button { model.selectFile(item) } label: {
                        Label(path, systemImage: staged ? "checkmark.circle" : "doc")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { model.stage(item) } label: {
                        Image(systemName: staged ? "minus.circle" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(staged ? "Unstage File" : "Stage File")
                    .accessibilityLabel(staged ? "Unstage \(path)" : "Stage \(path)")
                }
                .padding(5).background(model.file == item ? accent.opacity(0.15) : .clear)
                .help(path)
                .contextMenu {
                    Button("File History") { model.showFileHistory(path) }
                    Button("Blame at HEAD") { model.blameFile(path) }
                }
            }
        }
    }

    private func mainPane(_ repo: Repository) -> some View {
        let showingFile = model.inspection != nil || model.conflict != nil
        return ZStack {
            graph(repo)
                .opacity(showingFile ? 0 : 1)
                .allowsHitTesting(!showingFile)
                .accessibilityHidden(showingFile)
            if let conflict = model.conflict {
                VStack(spacing: 0) {
                    fileNavigation(conflict.path, expandable: false)
                    conflictEditor(conflict, rebasing: repo.rebasing)
                }
            } else if let inspection = model.inspection, let path = model.file?.path ?? model.commitFile {
                VStack(spacing: 0) {
                    fileNavigation(path, expandable: true)
                    if let file = model.file {
                        diffEditor(inspection, file: file, expanded: false)
                    } else {
                        FileInspectionView(path: path, inspection: inspection, canStage: false, selection: .constant([]))
                            .id(path)
                    }
                }
            }
        }
    }

    private func fileNavigation(_ path: String, expandable: Bool) -> some View {
        HStack(spacing: 12) {
            Button {
                model.closeFileViewer()
            } label: {
                Label("Commit Graph", systemImage: "chevron.left")
            }.buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            Divider().frame(height: 16)
            Text(path).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .truncationMode(.middle).help(path)
            Spacer()
            if expandable {
                Button("Expand") { expandFile = true }.buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12).frame(height: 39).background(panel)
        .overlay(alignment: .bottom) { rule.frame(height: 1) }
    }

    private func diffEditor(_ inspection: FileInspection, file: Workspace.File, expanded: Bool = false) -> some View {
        let canStage = !file.staged && inspection.patch.supportsSelection
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                if file.staged || model.repo?.unstaged.contains(file.path) == true {
                    Button(file.staged ? "Unstage File" : "Stage File") {
                        model.stage(file)
                        if expanded { expandFile = false }
                    }
                }
                if canStage {
                    Button("Stage Selected") {
                        model.stageSelection()
                        if expanded { expandFile = false }
                    }.buttonStyle(.borderedProminent).disabled(model.selectedLines.isEmpty)
                }
            }.padding(8)
            Divider()
            FileInspectionView(path: file.path, inspection: inspection, canStage: canStage, selection: $model.selectedLines)
                .id(file.path + (file.staged ? ":index" : ":worktree"))
        }
    }

    private func conflictEditor(_ conflict: Conflict, rebasing: Bool) -> some View {
        let ours = rebasing ? "Rebase Target" : "Current Version"
        let theirs = rebasing ? "Replayed Commit" : "Incoming Version"
        let blocks = Conflict.blocks(in: conflict.result)
        return VStack(spacing: 0) {
            HStack {
                Text(conflict.path).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Menu("Use Whole File") {
                    Button(ours) { model.resolve(conflict, side: 2) }
                    Button(theirs) { model.resolve(conflict, side: 3) }
                }.fixedSize()
                Button("Stage Resolution") { model.resolve(conflict) }
                    .buttonStyle(.borderedProminent).disabled(!conflict.editable || !blocks.isEmpty)
            }.padding(8)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ours).font(.caption.weight(.semibold)).padding(6)
                    code(conflict.ours ?? "File deleted")
                }.frame(minWidth: 140)
                VStack(alignment: .leading, spacing: 0) {
                    Text(theirs).font(.caption.weight(.semibold)).padding(6)
                    code(conflict.theirs ?? "File deleted")
                }.frame(minWidth: 140)
            }.frame(minHeight: 62, idealHeight: 100, maxHeight: 145)
            Divider()
            if conflict.editable {
                HStack {
                    Text("Result").font(.caption.weight(.semibold))
                    Spacer()
                    if let block = blocks.first {
                        Text("\(blocks.count) left").font(.caption).foregroundStyle(.orange)
                        Menu("Resolve First Conflict") {
                            Button("Accept " + ours) { model.conflict?.accept(block, ours: true) }
                            Button("Accept " + theirs) { model.conflict?.accept(block, ours: false) }
                        }.fixedSize()
                    }
                }.padding(6)
                TextEditor(text: Binding(get: { model.conflict?.result ?? "" }, set: { model.conflict?.result = $0 }))
                    .font(.system(size: 11, design: .monospaced)).accessibilityLabel("Conflict result")
            } else {
                Text("Choose a whole-file version to resolve this conflict.").padding()
            }
        }
    }

    private func code(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(base)
    }
}
