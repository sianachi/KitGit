"""Exercise the packaged desktop UI against a real repository."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tkinter as tk


def smoke(bundle, temporary):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("kitgit", bundle / "kitgit.py")
    kitgit = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(kitgit)
    kitgit.STATE = temporary / "session.json"
    repo = temporary / "repository with spaces"
    repo.mkdir()

    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()

    git("init", "-b", "main")
    git("config", "user.name", "KitGit CI")
    git("config", "user.email", "kitgit@example.test")
    git("config", "core.autocrlf", "false")
    path = repo / "notes with spaces.txt"
    path.write_bytes(b"first\nmiddle\nlast\n")
    git("add", ".")
    git("commit", "-m", "Initial")
    path.write_bytes(b"first edited\nmiddle\nlast edited\n")

    window = tk.Tk(className="KitGit")
    errors = []
    window.report_callback_exception = lambda _kind, error, _trace: errors.append(str(error))
    kitgit.messagebox.showerror = lambda _title, error, **_: errors.append(error)
    kitgit.messagebox.showinfo = kitgit.messagebox.showerror

    def wait():
        deadline = time.monotonic() + 20
        while app.busy and not errors and time.monotonic() < deadline:
            window.update()
            time.sleep(0.02)
        assert not errors, errors
        assert not app.busy, "Timed out waiting for KitGit"

    engine = bundle / ("engine.exe" if os.name == "nt" else "engine")
    app = kitgit.KitGit(window, str(engine), str(bundle / "KitGit.png"), str(repo))
    try:
        wait()
        assert app.icon.width() == 256
        assert app.repo["branch"] == "main"
        assert app.graph.find_all()
        row = next(row for row, item in app.rows.items() if item == ("unstaged", path.name))
        app.tree.focus(row)
        app.inspect_row()
        wait()
        detail = [child for frame in app.detail.winfo_children() for child in frame.winfo_children()]
        diff = next(child for child in detail if isinstance(child, tk.Text))
        start = diff.search("-first", "1.0")
        finish = diff.search("+first edited", "1.0")
        assert start and finish
        diff.tag_add("sel", start, finish + " lineend")
        stage = next(
            child for child in detail
            if child.winfo_class() == "TButton" and child.cget("text") == "Stage Selected Lines"
        )
        stage.invoke()
        wait()
        assert git("show", ":" + path.name) == "first edited\nmiddle\nlast"
        assert path.read_bytes() == b"first edited\nmiddle\nlast edited\n"
    finally:
        window.destroy()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as work:
        smoke(Path(sys.argv[1]).resolve(), Path(work))
    print("KitGit opened a repository and staged selected lines through its packaged desktop UI.")
