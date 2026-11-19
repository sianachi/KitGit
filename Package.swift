// swift-tools-version: 5.9
import PackageDescription

#if !os(macOS)
let platformSources = ["KitGitApp.swift", "Workspace.swift",
                       "FileInspectionView.swift", "RepositoryToolsView.swift"]
#else
let platformSources = ["DesktopBridge.swift"]
#endif

let package = Package(
    name: "KitGit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "KitGit", exclude: platformSources),
        .testTarget(name: "KitGitTests", dependencies: ["KitGit"])
    ]
)
