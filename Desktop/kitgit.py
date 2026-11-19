import argparse
import bisect
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk


BG = "#171923"
PANEL = "#222534"
FG = "#e4e8f7"
MUTED = "#a7afc8"
COLORS = ("#b797fa", "#75edbb", "#71bdff", "#f2a278", "#ed8bb7")
CONFIG_HOME = (
    os.environ.get("LOCALAPPDATA") if os.name == "nt" else os.environ.get("XDG_CONFIG_HOME")
)
STATE = Path(CONFIG_HOME or Path.home() / ".config") / "kitgit" / "session.json"


def request(engine, root, action, args, fields):
    result = subprocess.run(
        [engine], input=json.dumps(dict(root=root, action=action, args=args, **fields)),
        text=True, encoding="utf-8", capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(result.stderr or "The Git engine stopped unexpectedly.")
    return json.loads(result.stdout)


class KitGit:
    def __init__(self, window, engine, icon, directory):
        self.window = window
        self.engine = engine
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.busy = False
        self.repo = None
        self.tabs = []
        self.drafts = {}
        self.limit = 300
        self.rows = {}
        self.preview_image = None
        self.icon = tk.PhotoImage(file=icon)
        window.iconphoto(True, self.icon)
        window.title("KitGit")
        window.geometry("1200x760")
        window.minsize(840, 520)
        window.configure(bg=BG)
        style = ttk.Style()
        style.theme_use("clam")
        style.configure(".", background=PANEL, foreground=FG, fieldbackground=BG)
        style.configure("Treeview", rowheight=25)
        style.map("Treeview", background=[("selected", "#473669")])
        style.map("TButton", background=[("active", "#473669")])

        self.menu = tk.Menu(window)
        window.configure(menu=self.menu)
        self.install_menus()
        self.tabbar = ttk.Frame(window, padding=4)
        self.tabbar.pack(fill="x")
        self.toolbar = ttk.Frame(window, padding=4)
        self.toolbar.pack(fill="x")
        for title, action in (
            ("Open", self.open_dialog), ("Refresh", self.refresh), ("Fetch", self.fetch),
            ("Pull", self.pull), ("Push", self.push), ("Search", self.search), ("Browse Files", self.browse),
        ):
            ttk.Button(self.toolbar, text=title, command=action).pack(side="left", padx=2)
        self.operation = ttk.Frame(self.toolbar)
        self.operation.pack(side="right")
        self.status = ttk.Label(window, padding=5, text="Open a local Git repository to begin.")
        self.status.pack(side="bottom", fill="x")

        panes = ttk.Panedwindow(window, orient="horizontal")
        panes.pack(expand=True, fill="both")
        sidebar = ttk.Frame(panes)
        self.tree = ttk.Treeview(sidebar, show="tree", selectmode="browse")
        scroll = ttk.Scrollbar(sidebar, command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", expand=True, fill="both")
        scroll.pack(side="right", fill="y")
        self.tree.bind("<Double-1>", self.inspect_row)
        self.tree.bind("<Return>", self.inspect_row)
        self.tree.bind("<Button-3>", self.row_menu)
        self.tree.bind("<Menu>", self.row_menu)
        panes.add(sidebar, weight=1)

        self.main = ttk.Panedwindow(panes, orient="vertical")
        panes.add(self.main, weight=5)
        graph_area = ttk.Frame(self.main)
        self.graph_area = graph_area
        self.graph = tk.Canvas(graph_area, bg=BG, highlightthickness=0, yscrollincrement=26)
        graph_scroll = ttk.Scrollbar(graph_area, command=self.graph.yview)
        self.graph.configure(yscrollcommand=graph_scroll.set)
        self.graph.pack(side="left", expand=True, fill="both")
        graph_scroll.pack(side="right", fill="y")
        self.graph.bind("<MouseWheel>", lambda event: self.graph.yview_scroll(-int(event.delta / 120) * 3, "units"))
        self.graph.bind("<Button-4>", lambda event: self.graph.yview_scroll(-3, "units"))
        self.graph.bind("<Button-5>", lambda event: self.graph.yview_scroll(3, "units"))
        self.main.add(graph_area, weight=2)

        self.detail = ttk.Frame(self.main, padding=5)
        self.main.add(self.detail, weight=3)
        commit_area = ttk.Frame(window, padding=4)
        commit_area.pack(fill="x", before=self.status)
        ttk.Label(commit_area, text="Commit message").pack(side="left", padx=4)
        self.message = ttk.Entry(commit_area)
        self.message.pack(side="left", fill="x", expand=True, padx=4)
        ttk.Button(commit_area, text="Commit", command=self.commit).pack(side="right")

        window.bind("<Control-o>", lambda event: self.open_dialog())
        window.bind("<Control-r>", lambda event: self.refresh())
        window.bind("<Control-w>", lambda event: self.close())
        try:
            saved = json.loads(STATE.read_text())
            self.tabs = [path for path in saved["tabs"] if Path(path).is_dir()]
            directory = directory or saved.get("active") or (self.tabs[0] if self.tabs else None)
        except (OSError, ValueError, TypeError, KeyError):
            pass
        self.render_tabs()
        if directory:
            self.open(directory)

    def install_menus(self):
        folders = tk.Menu(self.menu, tearoff=False)
        self.menu.add_cascade(label="Repository", menu=folders)
        for label, callback in (
            ("Open Repository…", self.open_dialog), ("New Repository…", self.create),
            ("Clone Repository…", lambda: self.create(clone=True)), ("Close Tab", self.close),
            ("Add Remote…", self.add_remote), ("Create Branch…", self.create_branch),
            ("Add Worktree…", self.add_worktree), ("Save Stash…", self.create_stash),
            ("Pull Requests…", self.pull_requests), ("Load More Commits", self.load_more),
        ):
            folders.add_command(label=label, command=callback)

    def save(self):
        try:
            STATE.parent.mkdir(parents=True, exist_ok=True)
            temporary = STATE.with_name(f"session-{os.getpid()}.tmp")
            temporary.write_text(json.dumps({"tabs": self.tabs, "active": self.repo and self.repo["root"]}))
            temporary.replace(STATE)
        except OSError as error:
            self.status.configure(text=f"Could not save open tabs: {error}")

    def call(self, action, *args, done=None, changed=False, directory=None, **fields):
        if self.busy or (directory is None and self.repo is None):
            return
        root = directory if directory is not None else self.repo["root"]
        self.busy = True
        self.window.configure(cursor="watch")
        future = self.executor.submit(request, self.engine, root, action, args, fields)

        def finish():
            if not future.done():
                self.window.after(30, finish)
                return
            self.busy = False
            self.window.configure(cursor="")
            try:
                value = future.result()
            except (OSError, RuntimeError, ValueError) as error:
                if changed:
                    self.refresh()
                messagebox.showerror("KitGit", str(error), parent=self.window)
                return
            if done:
                done(value)
            elif changed:
                self.refresh()

        self.window.after(30, finish)

    def git(self, *args, **options):
        self.call("git", *args, **options)

    def ask(self, label, prompt, **options):
        return simpledialog.askstring(label, prompt, parent=self.window, **options)

    def confirm(self, text):
        return messagebox.askyesno("KitGit", text, parent=self.window)

    def open_dialog(self):
        path = filedialog.askdirectory(parent=self.window, title="Open Repository")
        if path:
            self.open(path)

    def open(self, path):
        if self.repo:
            self.drafts[self.repo["root"]] = self.message.get()

        def opened(repo):
            self.limit = 300
            self.message.delete(0, "end")
            self.message.insert(0, self.drafts.get(repo["root"], ""))
            self.render(repo)
            self.save()

        self.call("status", directory=path, done=opened)

    def create(self, clone=False):
        source = self.ask("Clone Repository", "Repository URL or path") if clone else None
        if clone and not source:
            return
        path = self.ask("Clone Destination" if clone else "New Repository", "Path to a new or empty directory")
        if path:
            self.call("create", *([source] if clone else []), directory=str(Path(path).expanduser().absolute()), done=self.open)

    def close(self):
        if not self.repo or self.busy:
            return
        path = self.repo["root"]
        self.drafts[path] = self.message.get()
        self.message.delete(0, "end")
        index = self.tabs.index(path)
        self.tabs.remove(path)
        self.repo = None
        self.tree.delete(*self.tree.get_children())
        self.graph.delete("all")
        self.clear_detail()
        for widget in self.operation.winfo_children():
            widget.destroy()
        self.status.configure(text="Open a local Git repository to begin.")
        self.render_tabs()
        self.save()
        if self.tabs:
            self.open(self.tabs[min(index, len(self.tabs) - 1)])

    def refresh(self):
        self.call("status", str(self.limit), done=self.render)

    def load_more(self):
        if self.repo and not self.busy and self.repo["canLoadMore"]:
            self.limit += 300
            self.refresh()

    def render_tabs(self):
        for widget in self.tabbar.winfo_children():
            widget.destroy()
        for path in self.tabs:
            label = Path(path).name or path
            if self.repo and path == self.repo["root"]:
                label = "● " + label
            ttk.Button(self.tabbar, text=label, command=lambda path=path: self.open(path)).pack(side="left", padx=2)
        ttk.Button(self.tabbar, text="+", width=3, command=self.open_dialog).pack(side="left", padx=2)

    def render(self, repo):
        self.repo = repo
        if repo["root"] not in self.tabs:
            self.tabs.append(repo["root"])
        self.render_tabs()
        branch = repo["branch"] or "Detached HEAD"
        self.window.title(f"KitGit · {Path(repo['root']).name} · {branch}")
        self.status.configure(text=f"{repo['root']}   ·   {branch}")
        self.rows.clear()
        self.tree.delete(*self.tree.get_children())
        sections = (
            ("Conflicts", "conflict", repo["conflicts"]), ("Unstaged", "unstaged", repo["unstaged"]),
            ("Staged", "staged", repo["staged"]), ("Local Branches", "branch", [b for b in repo["branches"] if not b["remote"]]),
            ("Remote Branches", "branch", [b for b in repo["branches"] if b["remote"]]),
            ("Tags", "tag", repo["tags"]), ("Worktrees", "worktree", repo["worktrees"]),
            ("Stashes", "stash", repo["stashes"]),
        )
        for title, kind, rows in sections:
            group = self.tree.insert("", "end", text=f"{title} ({len(rows)})", open=True)
            for item in rows:
                label = item
                if kind == "branch":
                    label = item["name"]
                elif kind == "stash":
                    label = item["message"]
                elif kind == "worktree":
                    label = Path(item["id"]).name + (" · Locked" if item["locked"] else "")
                row = self.tree.insert(group, "end", text=label)
                self.rows[row] = (kind, item)
        self.render_graph(repo["rows"], repo["width"])
        if repo["canLoadMore"]:
            y = len(repo["rows"]) * 26 + 13
            self.graph.create_text(20, y, text="Load More Commits", anchor="w", fill=COLORS[0], tags=("more",))
            self.graph.tag_bind("more", "<Button-1>", lambda event: self.load_more())
            self.graph.configure(scrollregion=(0, 0, 1000, y + 13))
        self.clear_detail()
        self.expand_detail(False)
        self.render_operation()

    def render_graph(self, rows, width):
        self.graph.delete("all")
        self.graph.yview_moveto(0)
        for i, row in enumerate(rows):
            y = i * 26 + 13
            x = 12 + row["lane"] * 12
            commit = row["commit"]
            tag = f"commit-{i}"
            for edge in row["above"]:
                a = 12 + edge["from"] * 12
                self.graph.create_line(a, y - 13, a, y, fill=COLORS[edge["color"] % len(COLORS)], width=2)
            for edge in row["below"]:
                a = 12 + edge["from"] * 12
                b = 12 + edge["to"] * 12
                self.graph.create_line(a, y, b, y + 13, fill=COLORS[edge["color"] % len(COLORS)], width=2)
            self.graph.create_oval(x - 4, y - 4, x + 4, y + 4, fill=COLORS[row["color"] % len(COLORS)], outline="")
            self.graph.create_text(14 + width * 12, y, anchor="w", fill=FG, tags=(tag,),
                                   text=f'{commit["id"][:8]}   {commit["subject"]}   {commit["refs"]}')
            self.graph.tag_bind(tag, "<Button-1>", lambda event, c=commit: self.show_commit(c["id"]))
            self.graph.tag_bind(tag, "<Button-3>", lambda event, c=commit: self.commit_menu(event, c))
        self.graph.configure(scrollregion=(0, 0, 1000, len(rows) * 26))

    def expand_detail(self, expanded):
        visible = str(self.graph_area) in self.main.panes()
        if expanded and visible:
            self.main.forget(self.graph_area)
        elif not expanded and not visible:
            self.main.insert(0, self.graph_area, weight=2)

    def clear_detail(self):
        for widget in self.detail.winfo_children():
            widget.destroy()
        self.preview_image = None

    def detail_bar(self, title):
        self.clear_detail()
        bar = ttk.Frame(self.detail)
        bar.pack(fill="x", pady=(0, 4))
        ttk.Label(bar, text=title).pack(side="left")
        return bar

    def button(self, bar, label, callback):
        ttk.Button(bar, text=label, command=callback).pack(side="right", padx=2)

    def text_area(self, value, editable=False, parent=None):
        frame = ttk.Frame(parent or self.detail)
        frame.pack(expand=True, fill="both")
        text = tk.Text(frame, wrap="none", bg=BG, fg=FG, insertbackground=FG, font="TkFixedFont",
                       undo=editable, relief="flat")
        scroll = ttk.Scrollbar(frame, command=text.yview)
        horizontal = ttk.Scrollbar(frame, orient="horizontal", command=text.xview)
        text.configure(yscrollcommand=scroll.set, xscrollcommand=horizontal.set)
        scroll.pack(side="right", fill="y")
        horizontal.pack(side="bottom", fill="x")
        text.pack(expand=True, fill="both")
        text.insert("1.0", value)
        if not editable:
            text.configure(state="disabled")
        return text

    def show_text(self, title, value):
        self.detail_bar(title)
        self.text_area(value)

    def inspect_row(self, event=None):
        row = self.tree.identify_row(event.y) if event and event.type == tk.EventType.ButtonPress else self.tree.focus()
        entry = self.rows.get(row)
        if not entry:
            return
        kind, item = entry
        if kind in ("staged", "unstaged"):
            self.show_file(item, kind)
        elif kind == "conflict":
            self.call("conflict", item, done=lambda data: self.show_conflict(item, data))
        elif kind == "branch":
            self.show_commit(item["id"])
        elif kind == "tag":
            self.show_commit("refs/tags/" + item)
        elif kind == "stash":
            self.call("showStash", item["hash"], done=lambda diff: self.show_text(item["message"], diff))
        elif kind == "worktree" and not item["bare"] and not item["missing"]:
            self.open(item["id"])

    def popup(self, event, entries):
        menu = tk.Menu(self.window, tearoff=False)
        for title, callback in entries:
            menu.add_command(label=title, command=callback)
        try:
            menu.tk_popup(event.x_root, event.y_root)
        finally:
            menu.grab_release()

    def row_menu(self, event):
        row = self.tree.identify_row(event.y) if event.type == tk.EventType.ButtonPress else self.tree.focus()
        entry = self.rows.get(row)
        if not entry:
            return
        self.tree.focus(row)
        self.tree.selection_set(row)
        kind, item = entry
        actions = [("Inspect", self.inspect_row)]
        if kind == "branch":
            name = item["name"]
            switch = ["switch", "--track", "--", name] if item["remote"] else ["switch", "--", name]
            actions += [
                ("Checkout", lambda: self.git(*switch, changed=True)),
                ("Merge…", lambda: self.confirm(f"Merge {name} into the current branch?")
                 and self.git("merge", "--no-edit", "--", item["id"], changed=True)),
                ("Rebase Onto…", lambda: self.start_rebase(item["id"])),
            ]
            if not item["remote"]:
                actions.append(("Delete Branch…", lambda: self.confirm(f"Delete the merged branch {name}?")
                                and self.git("branch", "--delete", "--", name, changed=True)))
        elif kind == "worktree":
            lock = "unlock" if item["locked"] else "lock"
            actions += [
                (lock.title(), lambda: self.git("worktree", lock, "--", item["id"], changed=True)),
                ("Remove Worktree…", lambda: self.confirm(f'Remove the clean worktree at {item["id"]}?')
                 and self.call("removeWorktree", item["id"], changed=True, done=lambda _: self.worktree_removed(item["id"]))),
            ]
        elif kind == "stash":
            key = item["hash"]
            actions += [
                ("Apply Stash", lambda: self.call("applyStash", key, changed=True)),
                ("Apply and Restore Staging", lambda: self.call("applyStash", key, "index", changed=True)),
                ("Pop Stash…", lambda: self.confirm("Apply this stash and remove it after successful restoration?")
                 and self.call("applyStash", key, "index", "pop", changed=True)),
                ("Drop Stash…", lambda: self.confirm(f'Delete {item["message"]}?')
                 and self.call("dropStash", key, changed=True)),
            ]
        elif kind in ("staged", "unstaged"):
            actions += [
                ("Unstage" if kind == "staged" else "Stage", lambda: self.stage(item, kind)),
                ("History", lambda: self.history(item, "HEAD")),
                ("Blame", lambda: self.blame(item, "HEAD")),
            ]
        self.popup(event, actions)

    def worktree_removed(self, path):
        self.tabs = [tab for tab in self.tabs if Path(tab).resolve() != Path(path).resolve()]
        self.save()
        self.refresh()

    def stage(self, path, kind):
        self.call("stage", path, "unstage" if kind == "staged" else "stage", changed=True)

    def show_file(self, path, kind):
        self.call("file", path, kind, done=lambda data: self.render_file(path, kind, data))

    def render_file(self, path, kind, data, mode="diff"):
        bar = self.detail_bar(path)
        expanded = str(self.graph_area) not in self.main.panes()
        self.button(bar, "Commit Graph" if expanded else "Expand", lambda: (
            self.expand_detail(not expanded), self.render_file(path, kind, data, mode)))
        if kind in ("staged", "unstaged"):
            self.button(bar, "Unstage File" if kind == "staged" else "Stage File", lambda: self.stage(path, kind))
        self.button(bar, "History", lambda: self.history(path, kind if len(kind) >= 40 else "HEAD"))
        self.button(bar, "Blame", lambda: self.blame(path, kind if len(kind) >= 40 else "HEAD"))
        for name in ("after", "before", "split", "diff"):
            self.button(bar, name.title(), lambda name=name: self.render_file(path, kind, data, name))
        if mode == "split":
            sides = ttk.Panedwindow(self.detail, orient="horizontal")
            sides.pack(expand=True, fill="both")
            for side, color in (("left", "#ff9aaa"), ("right", COLORS[1])):
                frame = ttk.Frame(sides)
                sides.add(frame, weight=1)
                rows = [line.get(side, "") for line in data["split"]]
                text = self.text_area("\n".join(rows), parent=frame)
                text.tag_configure("changed", foreground=color)
                for i, line in enumerate(rows, 1):
                    if len(line) > 7 and line[7] in "+-":
                        text.tag_add("changed", f"{i}.0", f"{i}.end")
            return
        if mode != "diff":
            snapshot = data[mode]
            if snapshot.get("image"):
                try:
                    self.preview_image = tk.PhotoImage(data=snapshot["image"])
                    ttk.Label(self.detail, image=self.preview_image).pack(expand=True)
                    return
                except tk.TclError:
                    pass
            content = snapshot["text"] or ""
            text = self.text_area(content)
            if snapshot["tokens"]:
                offsets = [0]
                for line in content.split("\n")[:-1]:
                    offsets.append(offsets[-1] + len(line.encode("utf-16-le")) // 2 + 1)

                def location(offset):
                    row = bisect.bisect_right(offsets, offset) - 1
                    return f"{row + 1}.{offset - offsets[row]}"

                for token_kind, color in enumerate((MUTED, COLORS[1], COLORS[0], COLORS[3], COLORS[2]), 1):
                    text.tag_configure(f"syntax-{token_kind}", foreground=color)
                for start, length, token_kind in snapshot["tokens"]:
                    text.tag_add(f"syntax-{token_kind}", location(start), location(start + length))
            return
        text = self.text_area(data["diff"] or "No textual diff")
        for token, color in (("+", COLORS[1]), ("-", "#ff9aaa"), ("@", COLORS[0])):
            text.tag_configure(token, foreground=color)
        for index, line in enumerate(data["diff"].split("\n")):
            if line and line[0] in "+-@":
                text.tag_add(line[0], f"{index + 1}.0", f"{index + 1}.end")
        text.tag_configure("inline", background="#413953")
        text.tag_lower("inline", "sel")
        for line, ranges in data["inline"].items():
            row = int(line) + 1
            for start, length in ranges:
                text.tag_add("inline", f"{row}.{start}", f"{row}.{start + length}")
        if kind == "unstaged" and data["lines"]:
            self.button(bar, "Stage Selected Lines", lambda: self.stage_lines(path, data, text))

    def stage_lines(self, path, data, text):
        selection = text.tag_ranges("sel")
        if selection:
            start, end = map(str, selection)
            low = int(start.split(".")[0]) - 1
            high, column = map(int, end.split("."))
            ids = [i for i in data["lines"] if low <= i < high - (column == 0)]
            if ids:
                self.call("stageLines", path, text=data["diff"], ids=ids, changed=True)
                return
        messagebox.showinfo("KitGit", "Select added or removed lines in the diff first.", parent=self.window)

    def show_conflict(self, path, data, mode="result"):
        bar = self.detail_bar(path)
        content = self.text_area(data.get(mode) or "", editable=mode == "result" and data["editable"])
        for side, number in (("Ours", "2"), ("Theirs", "3")):
            self.button(bar, f"Accept {side}", lambda side=side, number=number:
                        self.confirm(f"Resolve {path} using {side.lower()}?")
                        and self.call("resolve", path, number, conflict=data["version"], changed=True))
        for name in ("ours", "theirs", "result"):
            self.button(bar, name.title(), lambda name=name: self.show_conflict(path, data, name))
        if mode == "result" and data["editable"]:
            def accept_block():
                line = int(content.index("insert").split(".")[0]) - 1
                block = next((start for start, end in data["blocks"] if start <= line <= end), None)
                if block is None:
                    messagebox.showinfo("KitGit", "Place the cursor inside the conflict block first.", parent=self.window)
                    return
                self.pick(f"Resolve block at line {block + 1}", [("Ours", "2"), ("Theirs", "3")],
                          lambda side: self.call("acceptConflictBlock", path, str(block), side[1],
                                                 conflict=data["version"], text=content.get("1.0", "end-1c"),
                                                 done=lambda updated: self.show_conflict(path, updated)),
                          label=lambda side: side[0])
            if data["blocks"]:
                self.button(bar, "Accept Block…", accept_block)
            self.button(bar, "Stage Resolution", lambda: self.call(
                "resolve", path, text=content.get("1.0", "end-1c"), conflict=data["version"], changed=True))

    def render_operation(self):
        for widget in self.operation.winfo_children():
            widget.destroy()
        operation = self.repo.get("operation")
        if operation:
            ttk.Label(self.operation, text=f"{operation.title()} in progress").pack(side="left")
            if operation == "rebase":
                self.button(self.operation, "Abort…", lambda: self.finish_rebase("--abort"))
                self.button(self.operation, "Skip…", lambda: self.finish_rebase("--skip"))
                self.button(self.operation, "Continue", lambda: self.call("finishRebase", "--continue", changed=True))
            else:
                self.button(self.operation, "Abort…", lambda: self.confirm(f"Abort {operation}?")
                            and self.git(operation, "--abort", changed=True))
                args = ("commit", "--no-edit") if operation == "merge" else (operation, "--continue")
                self.button(self.operation, "Continue", lambda: self.git(*args, changed=True))
        elif self.repo["savedChanges"]:
            self.button(self.operation, "Restore Saved Changes", lambda: self.call("restoreSavedChanges", changed=True))
            self.button(self.operation, "Keep in Stash", lambda: self.call("restoreSavedChanges", "keep", changed=True))

    def finish_rebase(self, action):
        if self.confirm("Abort this rebase?" if action == "--abort" else "Skip the current commit?"):
            self.call("finishRebase", action, changed=True)

    def start_rebase(self, ref):
        if self.repo.get("operation"):
            return
        stash = self.repo["dirty"]
        question = "Stash working changes and rebase onto " if stash else "Rebase onto "
        if self.confirm(question + ref + "?"):
            extras = ["stash"] if stash else []
            self.call("rebase", ref, self.repo["branch"], *extras, changed=True)

    def show_commit(self, ref):
        self.git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}",
                 done=lambda revision: self.commit_detail(revision.rstrip("\n")))

    def commit_detail(self, revision):
        def show(body):
            def files(paths):
                bar = self.detail_bar(revision[:12])
                self.button(bar, "Changed Files", lambda: self.pick("Changed Files", paths,
                             lambda path: self.show_file(path, revision)))
                self.text_area(body)
            self.call("commitFiles", revision, done=files)
        self.git("show", "-s", "--format=fuller", revision, "--", done=show)

    def commit_menu(self, event, commit):
        revision = commit["id"]
        self.popup(event, [
            ("Inspect Commit", lambda: self.show_commit(revision)),
            ("Create Tag…", lambda: self.create_tag(revision)),
            ("Cherry-pick…", lambda: self.confirm(f'Cherry-pick "{commit["subject"]}"?')
             and self.git("cherry-pick", "--no-edit", revision, changed=True)),
            ("Revert…", lambda: self.confirm(f'Revert "{commit["subject"]}"?')
             and self.git("revert", "--no-edit", revision, changed=True)),
            ("Interactive Rebase…", lambda: self.call("plan", revision, done=self.edit_plan)),
        ])

    def edit_plan(self, plan):
        dialog, listbox = self.list_dialog("Interactive Rebase")

        def populate(selected=0):
            listbox.delete(0, "end")
            for entry in plan["entries"]:
                listbox.insert("end", f'{entry["action"]:7}  {entry["subject"]}')
            listbox.selection_set(selected)

        def update(action=None, shift=0):
            selection = listbox.curselection()
            if not selection:
                return
            position = selection[0]
            other = position + shift
            entries = plan["entries"]
            if action:
                entries[position]["action"] = action
            elif 0 <= other < len(entries):
                entries[position], entries[other] = entries[other], entries[position]
                position = other
            populate(position)

        def start():
            if self.confirm("Rewrite the selected commits on this branch?"):
                dialog.destroy()
                self.call("runPlan", plan=plan, changed=True)

        bar = ttk.Frame(dialog, padding=4)
        bar.pack(fill="x")
        for action in ("pick", "squash", "fixup", "drop"):
            ttk.Button(bar, text=action.title(), command=lambda action=action: update(action)).pack(side="left")
        ttk.Button(bar, text="Up", command=lambda: update(shift=-1)).pack(side="left")
        ttk.Button(bar, text="Down", command=lambda: update(shift=1)).pack(side="left")
        self.button(bar, "Start Rebase", start)
        populate()

    def list_dialog(self, title):
        dialog = tk.Toplevel(self.window, class_="KitGit")
        dialog.title(title)
        dialog.transient(self.window)
        dialog.grab_set()
        dialog.geometry("650x360")
        frame = ttk.Frame(dialog)
        frame.pack(expand=True, fill="both")
        listbox = tk.Listbox(frame, bg=BG, fg=FG, selectbackground="#473669")
        scroll = ttk.Scrollbar(frame, command=listbox.yview)
        listbox.configure(yscrollcommand=scroll.set)
        scroll.pack(side="right", fill="y")
        listbox.pack(expand=True, fill="both")
        listbox.focus_set()
        dialog.bind("<Escape>", lambda event: dialog.destroy())
        return dialog, listbox

    def pick(self, title, values, callback, label=str):
        dialog, listbox = self.list_dialog(title)
        for value in values:
            listbox.insert("end", label(value))
        if values:
            listbox.selection_set(0)

        def choose(event=None):
            selected = listbox.curselection()
            if selected:
                dialog.destroy()
                callback(values[selected[0]])

        listbox.bind("<Double-1>", choose)
        listbox.bind("<Return>", choose)
        ttk.Button(dialog, text="Select", command=choose).pack(pady=4)

    def search(self):
        if self.repo and (query := self.ask("Search Commits", "Commit hash or message")):
            self.call("search", query, done=lambda rows: self.show_history("Search Results", rows))

    def history(self, path, revision):
        self.call("history", path, revision, done=lambda rows: self.show_history("File History", rows))

    def show_history(self, title, rows):
        self.pick(title, rows, lambda commit: self.show_commit(commit["id"]),
                  lambda commit: f'{commit["id"][:8]}  {commit["subject"]}')

    def blame(self, path, revision):
        self.git("blame", "--date=short", revision, "--", path,
                 done=lambda value: self.show_text("Blame · " + path, value))

    def browse(self):
        self.call("files", done=lambda files: self.pick("Repository Files", files,
                  lambda path: self.show_file(path, "unstaged")))

    def commit(self):
        text = self.message.get().strip()
        if not text or not self.repo:
            return
        if not self.repo["staged"] or self.repo.get("operation"):
            messagebox.showinfo("KitGit", "Stage changes or finish the current operation first.", parent=self.window)
            return

        def committed(_):
            self.message.delete(0, "end")
            self.refresh()
        self.git("commit", "-F", "-", text=text, changed=True, done=committed)

    def fetch(self):
        self.git("fetch", "--all", changed=True)

    def pull(self):
        self.git("pull", "--ff-only", "--no-rebase", changed=True)

    def push(self):
        if not self.repo or not self.repo["branch"]:
            return
        branch = self.repo["branch"]

        def push_to(remote):
            if self.confirm(f"Push {branch} to {remote}?"):
                self.call("push", branch, remote, changed=True)
        self.pick("Push to Remote", self.repo["remotes"], push_to)

    def add_remote(self):
        if self.repo and (name := self.ask("Add Remote", "Remote name")) and (url := self.ask("Add Remote", "Remote URL")):
            self.git("remote", "add", "--", name, url, changed=True)

    def create_branch(self):
        if self.repo and (name := self.ask("Create Branch", "New branch name")):
            self.git("check-ref-format", "--branch", name,
                     done=lambda _: self.git("switch", "-c", name, changed=True))

    def create_tag(self, revision):
        if name := self.ask("Create Tag", "Tag name"):
            self.git("tag", "--", name, revision, changed=True)

    def add_worktree(self):
        if not self.repo or not (branch := self.ask("Add Worktree", "Branch name")):
            return
        path = self.ask("Add Worktree", "Path to a new worktree")
        if path:
            new = not any(item["name"] == branch and not item["remote"] for item in self.repo["branches"])
            destination = str(Path(path).expanduser().absolute())
            self.call("addWorktree", destination, branch, *(["new"] if new else []),
                      done=lambda _: self.open(destination), changed=True)

    def create_stash(self):
        if not self.repo:
            return
        message = self.ask("Save Stash", "Optional stash message")
        if message is not None:
            extras = ["untracked"] if self.confirm("Include untracked files in this stash?") else []
            self.call("createStash", *extras, text=message, changed=True)

    def pull_requests(self):
        if not self.repo:
            return
        remotes = [remote["name"] for remote in self.repo["github"]]
        if not remotes:
            messagebox.showinfo("KitGit", "Add a GitHub.com remote first.", parent=self.window)
            return
        self.pick("GitHub Remote", remotes, lambda remote: self.call(
            "pullRequests", remote, "list", done=lambda rows: self.show_pull_requests(remote, rows)))

    def show_pull_requests(self, remote, rows):
        dialog, listbox = self.list_dialog("Pull Requests")
        for pr in rows:
            listbox.insert("end", f'#{pr["number"]}  {pr["title"]}')

        def act(action):
            selection = listbox.curselection()
            if not selection:
                return
            pr = rows[selection[0]]
            if action == "diff":
                dialog.destroy()
                self.call("pullRequests", remote, action, request=pr,
                          done=lambda diff: self.show_text(pr["title"], pr["body"] + "\n\n" + diff))
            elif self.confirm(f'{action.title()} pull request #{pr["number"]}?'):
                dialog.destroy()
                self.call("pullRequests", remote, action, request=pr, changed=True)

        def draft():
            dialog.destroy()
            branch = self.repo["branch"]
            title = self.ask("Draft Pull Request", f"Title for pushed branch {branch}")
            if not title or not branch:
                return
            base = self.ask("Draft Pull Request", "Base branch (empty uses the default)")
            if base is not None:
                body = self.ask("Draft Pull Request", "Optional description")
                if body is not None and self.confirm("Publish this draft pull request?"):
                    self.call("pullRequests", remote, "draft", title, branch, base, text=body,
                              done=lambda url: self.show_text("Draft Pull Request", url))

        bar = ttk.Frame(dialog, padding=4)
        bar.pack(fill="x")
        for label, action in (("Diff", "diff"), ("Checkout", "checkout"), ("Approve", "approve"), ("Squash Merge", "squash")):
            self.button(bar, label, lambda action=action: act(action))
        self.button(bar, "New Draft…", draft)
        listbox.bind("<Return>", lambda event: act("diff"))
        listbox.bind("<Double-1>", lambda event: act("diff"))


def main():
    parser = argparse.ArgumentParser(description="KitGit desktop client")
    parser.add_argument("--engine", required=True)
    parser.add_argument("--icon", required=True)
    parser.add_argument("directory", nargs="?")
    args = parser.parse_args()
    window = tk.Tk(className="KitGit")
    KitGit(window, args.engine, args.icon, args.directory)
    window.mainloop()


if __name__ == "__main__":
    main()
