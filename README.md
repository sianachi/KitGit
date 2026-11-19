# KitGit

KitGit is a native macOS Git client for existing local repositories. It requires macOS 14 or later and uses the system Git at `/usr/bin/git`. Building requires a Swift toolchain.

```sh
./scripts/build-app
open .build/KitGit.app
```

Open a repository with **⌘O**. The sidebar lists local and remote-tracking branches. Select a commit in the graph to inspect it. Use **⌘R** to refresh after making changes outside KitGit.

To commit part of a change, select an unstaged file, check the added and removed lines you want, and click **Stage Selected**. Review the staged version before committing. Use **Stage File** for binary files and diffs where line selection is unavailable.

To rebase, right-click the destination branch and choose **Rebase Current Branch onto…**. If the working tree is dirty, the confirmation offers **Stash and Rebase**. Select each conflicted file, edit the result or accept a side, then stage the resolution. Use **Continue Rebase**, or confirm **Skip Commit** or **Abort**. Reopening the repository shows any unfinished rebase.

KitGit attempts to restore approved stashes with their original staged state when the rebase ends. It retains a recovery copy in the Git stash list. If restoration conflicts, inspect the working tree and index before applying the stash again.

Run the local Git integration tests with `swift test`.

## Repositories, worktrees, and stashes

Use the **+** in the tab strip to open another checkout or repository. KitGit restores the tab list on relaunch and keeps commit drafts per tab while the app is running. The **Repository** menu can clone, initialize, or add a remote.

Use **+** beside **Worktrees** to create a checkout on a new branch or an existing unchecked-out branch. Select a worktree to open it in a tab. Right-click to lock, unlock, or remove a linked worktree. Remove it from a sibling checkout. KitGit checks for tracked changes, untracked and ignored files, and Git operations before removing the checkout.

Use **+** beside **Stashes** to save changes. Select a stash to preview its patch. Right-click to apply, apply with the original staging, pop, or drop. Pop removes the saved entry after a successful apply. Drop asks for confirmation.

## History and remotes

Fetch all configured remotes, fast-forward from the current branch's upstream, or push the current branch to the same name on a selected remote. Use branch and commit context menus for merge, local branch deletion, lightweight tags, cherry-pick, and revert. Merge, cherry-pick, and revert conflicts use the existing conflict editor.

For an interactive rebase, stash or commit working changes first. Right-click the base commit and choose **Interactively Rebase Commits Above Here**. A linear range can be reordered, squashed, fixed up, or dropped. Use **Search** for a commit message or hash, and right-click a file to see its history or blame.

For GitHub.com remotes, **Pull Requests** uses an existing GitHub CLI sign-in. It can list open pull requests, show their diffs, check them out, publish drafts from a pushed branch, approve, and squash merge. GitHub permissions and repository rules determine which actions are available.

## File preview and diff

Select a changed file in the working directory or a commit to open it in the center pane. The file list remains on the right. Use **Commit Graph** or **Esc** to return to the graph, or **Browse Files** to find an unchanged file. **Before** and **After** show the complete versions. Text previews have line numbers, and supported images render inline. **Diff** offers unified and split layouts. Both highlight the changed spans within paired lines. Common source and configuration formats also get syntax coloring. **Expand** opens a larger view, with line and hunk staging available for supported unstaged patches. Each version has a 12 MB preview limit.

## Linux desktop

KitGit on Linux uses the same Swift Git engine as macOS and a Tk desktop interface. Install Swift 5.9 or later, Git at `/usr/bin/git`, and Python 3.8 or later with Tk support. On Debian and Ubuntu, the Tk package is `python3-tk`. Pull request features also require an authenticated GitHub CLI installation.

```sh
./scripts/build-linux
.build/KitGit-linux/kitgit
```

Pass a repository directory to open it at launch. To install KitGit for your user and add the cat icon and launcher to your desktop's application menu, run `./scripts/build-linux --install`.

Double-click a branch, commit, worktree, stash, or changed file to inspect it. Right-click an item for its available operations. To stage part of a file, select the changed lines in the unified diff and choose **Stage Selected Lines**. Run `swift test` on either platform to exercise the shared Git workflows.

### Arch Linux and Omarchy

Download the **KitGit-linux-x64** artifact from the latest [GitHub Release](https://github.com/sianachi/KitGit/releases/latest). The packaged Swift engine runs without a Swift installation. Install Python, Tk, Git, and XWayland for Omarchy, then unpack and install the app for your user.

```sh
sudo pacman -Syu --needed git python tk xorg-xwayland
mkdir -p kitgit
tar -xzf KitGit-linux-x64.tar.gz -C kitgit
./kitgit/install
```

Launch **KitGit** from your app menu or run `./kitgit/kitgit` directly. For builds from source on Arch, [ArchWiki lists the Swift toolchain packages](https://wiki.archlinux.org/title/Swift).

## Windows desktop

Download **KitGit-windows-x64** or **KitGit-windows-arm64**, extract the ZIP, and open `KitGit.cmd`. Install Git for Windows and Python with Tcl/Tk support and add both to PATH. The native engine also needs the matching Swift 6.4.2 runtime. The [Swift for Windows installer](https://www.swift.org/install/windows/) provides it.

To build from source with the Swift toolchain set up, run `.\scripts\build-windows.ps1` in PowerShell. The launcher is at `.build\KitGit-windows\KitGit.cmd`.

## Continuous integration

[Build KitGit](.github/workflows/build.yml) runs on pushes and pull requests and can be started manually. It tests and packages x86-64 and ARM64 builds of Windows, Linux, and macOS. x86-64 covers both Intel and AMD 64-bit systems. An additional Arch Linux job installs and smoke-tests the packaged x86-64 Linux app. The macOS archives contain ad hoc signed app bundles for testing.

To publish a version, update the macOS bundle version in `scripts/build-app`, commit it, and push a version tag such as `v0.2.1`. CI publishes all six downloads to [GitHub Releases](https://github.com/sianachi/KitGit/releases) after the platform builds and the Arch compatibility job pass.
