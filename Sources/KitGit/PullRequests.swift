import Foundation
struct GitHubRemote: Identifiable, Codable {
    let name: String
    let slug: String
    var id: String { name }

    init?(name: String, address: String) {
        let path: String
        if address.hasPrefix("git@github.com:") {
            path = String(address.dropFirst("git@github.com:".count))
        } else if let url = URL(string: address), url.host?.lowercased() == "github.com",
                  ["https", "ssh"].contains(url.scheme ?? ""), url.port == nil {
            path = url.path
        } else {
            return nil
        }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        let repository = parts[1].hasSuffix(".git") ? parts[1].dropLast(4) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !repository.isEmpty, [parts[0], repository].allSatisfy({
            $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains)
        }) else { return nil }
        self.name = name
        slug = parts[0] + "/" + repository
    }
}

struct PullRequest: Identifiable, Codable {
    struct Author: Codable { let login: String }

    let number: Int
    let title: String
    let body: String
    let author: Author?
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let isDraft: Bool
    var id: Int { number }
}

struct GitHubPullRequests {
    let git: Git
    let remote: GitHubRemote
    var executable: URL? = nil

    private func run(_ args: [String]) throws -> String {
        #if os(Windows)
        let location = executable ?? Git.windowsExecutable("gh.exe")
        #else
        let installed = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh", "/usr/bin/gh", "/snap/bin/gh"]
        let location = executable ?? installed.first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
        #endif
        guard let location else {
            throw GitFailure(message: "Install GitHub CLI and sign in with gh auth login to use GitHub pull requests.")
        }
        return try git.run(args, environment: [
            "GH_PROMPT_DISABLED": "1", "GH_HOST": "github.com", "NO_COLOR": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ], executable: location)
    }

    private func pr(_ args: [String]) throws -> String {
        try run(["pr"] + args + ["--repo", "github.com/" + remote.slug])
    }

    func list() throws -> [PullRequest] {
        let output = try pr(["list", "--limit", "100", "--json",
                             "number,title,body,author,headRefName,headRefOid,baseRefName,isDraft"])
        return try JSONDecoder().decode([PullRequest].self, from: Data(output.utf8))
    }

    func diff(_ request: PullRequest) throws -> String {
        try pr(["diff", String(request.number), "--color", "never"])
    }

    func checkout(_ request: PullRequest) throws {
        guard try !git.operationInProgress(),
              try git.run(["status", "--porcelain", "-z"]).isEmpty else {
            throw GitFailure(message: "Finish the current operation and commit or stash changes before checkout.")
        }
        _ = try pr(["checkout", String(request.number)])
    }

    func createDraft(title: String, body: String, head: String, base: String) throws -> String {
        var options = ["create", "--draft", "--title", title, "--body", body, "--head", head]
        if !base.isEmpty { options += ["--base", base] }
        return try pr(options).droppingFinalNewline
    }

    func approve(_ request: PullRequest) throws {
        _ = try run(["api", "--hostname", "github.com", "--method", "POST",
                     "repos/\(remote.slug)/pulls/\(request.number)/reviews",
                     "-f", "event=APPROVE", "-f", "commit_id=" + request.headRefOid])
    }

    func squashMerge(_ request: PullRequest) throws {
        struct Result: Decodable { let merged: Bool; let message: String }
        let response = try run(["api", "--hostname", "github.com", "--method", "PUT",
                                "repos/\(remote.slug)/pulls/\(request.number)/merge",
                                "-f", "merge_method=squash", "-f", "sha=" + request.headRefOid])
        let result = try JSONDecoder().decode(Result.self, from: Data(response.utf8))
        guard result.merged else { throw GitFailure(message: result.message) }
    }
}

#if canImport(SwiftUI)
import SwiftUI

struct PullRequestsView: View {
    let repo: Repository
    let onCheckout: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedRemote = ""
    @State private var requests: [PullRequest] = []
    @State private var selection: Int?
    @State private var busy = false
    @State private var error: String?
    @State private var diff: String?
    @State private var action: String?
    @State private var creating = false
    @State private var title = ""
    @State private var description = ""
    @State private var base = ""

    private var client: GitHubPullRequests? {
        repo.gitHubRemotes.first(where: { $0.name == selectedRemote }).map {
            GitHubPullRequests(git: Git(root: repo.root), remote: $0)
        }
    }

    private var selected: PullRequest? { requests.first { $0.number == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pull Requests").font(.headline)
                Picker("Remote", selection: $selectedRemote) {
                    ForEach(repo.gitHubRemotes) { Text($0.name + " / " + $0.slug).tag($0.name) }
                }.fixedSize()
                Button("Refresh") { load() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("New Draft…") { creating = true }.disabled(repo.branch.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12).disabled(busy)
            Divider()
            HSplitView {
                List(requests, selection: $selection) { request in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("#\(request.number)  " + request.title).lineLimit(2)
                        Text(request.isDraft ? "Draft" : request.author?.login ?? "")
                            .foregroundStyle(.secondary).font(.caption)
                    }.tag(request.number)
                }.frame(minWidth: 235, idealWidth: 275)
                if let request = selected {
                    details(request).frame(minWidth: 490)
                } else {
                    ContentUnavailableView(requests.isEmpty ? "No open pull requests" : "Select a pull request",
                                           systemImage: "arrow.triangle.pull")
                        .frame(minWidth: 490)
                }
            }
            if let error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
        }
        .frame(width: 840, height: 565)
        .task {
            selectedRemote = repo.gitHubRemotes.first?.name ?? ""
        }
        .onChange(of: selectedRemote) { _, _ in load() }
        .onChange(of: selection) { _, _ in diff = nil }
        .sheet(isPresented: $creating) { createForm }
        .alert(action ?? "", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } }),
               presenting: action) { value in
            Button("Cancel", role: .cancel) {}
            Button(value, role: value == "Squash Merge" ? .destructive : nil) {
                guard let request = selected, let client else { return }
                work({
                    if value == "Approve" { try client.approve(request) }
                    else { try client.squashMerge(request) }
                    return try client.list()
                }, done: { requests = $0 })
            }
        } message: { value in
            Text("\(value) #\(selected?.number ?? 0) at \(selected?.headRefOid.prefix(7) ?? "") in \(client?.remote.slug ?? "").")
        }
    }

    private func details(_ request: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(request.title).font(.title3.bold())
            Text(request.headRefName + " → " + request.baseRefName)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("View Diff") {
                    guard let client else { return }
                    work({ try client.diff(request) }, done: {
                        if self.selection == request.number { diff = $0 }
                    })
                }
                Button("Check Out") {
                    guard let client else { return }
                    work({ try client.checkout(request) }, done: {
                        onCheckout()
                        dismiss()
                    })
                }.disabled(repo.operationInProgress || repo.dirty)
                Button("Approve…") { action = "Approve" }.disabled(request.isDraft)
                Button("Squash Merge…") { action = "Squash Merge" }.disabled(request.isDraft)
            }.disabled(busy)
            Divider()
            ScrollView(diff == nil ? .vertical : [.vertical, .horizontal]) {
                Text(diff ?? request.body)
                    .font(diff == nil ? .body : .system(size: 11, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(12)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Draft Pull Request").font(.headline)
            Text("Publish a draft from \(repo.branch) to \(client?.remote.slug ?? ""). Push the head branch first.")
                .foregroundStyle(.secondary)
            TextField("Title", text: $title)
            TextField("Base branch (optional)", text: $base)
            Text("Description").font(.caption)
            TextEditor(text: $description).frame(height: 135)
            HStack {
                Spacer()
                Button("Cancel") { creating = false }.keyboardShortcut(.cancelAction)
                Button("Publish Draft") {
                    guard let client else { return }
                    let input = (title, description, repo.branch, base)
                    creating = false
                    work({
                        _ = try client.createDraft(title: input.0, body: input.1, head: input.2, base: input.3)
                        return try client.list()
                    }, done: { requests = $0 })
                }.keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(16).frame(width: 460)
    }

    private func load() {
        guard let client else { return }
        requests = []
        selection = nil
        work({ try client.list() }, done: { requests = $0 })
    }

    private func work<Value: Sendable>(_ task: @escaping @Sendable () throws -> Value,
                                       done: @escaping (Value) -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { done(try await Task.detached(operation: task).value) }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
