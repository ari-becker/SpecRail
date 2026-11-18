"""What the tests share: the project they run in, positions counted the way
the server and the client agreed, and edits applied the way an editor
applies them."""

import os
import shutil
import subprocess
from pathlib import Path
from urllib.parse import unquote, urlparse

from lsprotocol import types

REPOSITORY = Path(__file__).resolve().parents[2]

#: The specrail under test: `zig build test-lsp` names the one it built.
SPECRAIL = os.environ.get("SPECRAIL") or str(REPOSITORY / "zig-out" / "bin" / "specrail")

#: What the server and git run with: none of the user's configuration.
ENV = {
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "HOME": "/nonexistent/specrail-lsp-tests",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": os.devnull,
}

#: Written apart from the forms it marks, so that this file holds no
#: reference lines of its own.
MARKER = "specrail" + ":"

A_SPEC = """\
# § 1 Login

## § 1.1 Password
```toml
x-owner = "auth"
```

It MUST accept a password.

## § 1.2 Café 🔑

It MUST accept a key.
"""

B_SPEC = """\
# § 1 Waits
```toml
dependencies = [
  "specs/a.spec.md § 1.2 Café 🔑",
]
```

It MUST wait.
"""

#: The forms of the test file's reference lines, one per line.
REFERENCES = [
    "specs/a.spec.md § 1.1 Password",
    "specs/a.spec.md § 1.2 Café 🔑",
    "specs/b.spec.md § 1 Waits",
]


def reference_lines(forms: list[str]) -> str:
    """A test file whose lines reference `forms`."""
    return "".join(f"# {MARKER} {form}\n" for form in forms)


#: The project every test starts from, as `specrail fmt` leaves it. The
#: section titles hold characters that UTF-8, UTF-16 and UTF-32 count
#: differently, so a column counted in the wrong encoding shows.
PROJECT = {
    "specrail.toml": 'spec_root = "specs"\n',
    "specs/a.spec.md": A_SPEC,
    "specs/b.spec.md": B_SPEC,
    "src/t.py": reference_lines(REFERENCES),
}


def write(root: Path, files: dict[str, str | None]) -> None:
    """Writes `files` under `root`, removing each one given as None."""
    for path, text in files.items():
        target = root / path
        if text is None:
            target.unlink(missing_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


def make_project(root: Path, changes: dict[str, str | None]) -> None:
    """The project, with `changes` made, in a new git work tree at `root`."""
    write(root, {**PROJECT, **changes})
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=root, env=ENV, check=True)


def read(root: Path, path: str) -> str:
    return (root / path).read_text(encoding="utf-8")


def specrail(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Runs the specrail CLI in `root`."""
    return subprocess.run(
        [SPECRAIL, *args], cwd=root, env=ENV, capture_output=True, text=True, check=False
    )


def copy(root: Path, scratch: Path, files: dict[str, str | None] | None = None) -> Path:
    """A copy of the project at `scratch`, with `files` written."""
    shutil.copytree(root, scratch)
    write(scratch, files or {})
    return scratch


def as_cli_would(
    root: Path, scratch: Path, *args: str, files: dict[str, str] | None = None
) -> Path:
    """A copy of the project at `scratch`, with `files` written, after the
    CLI has run there with `args`."""
    copy(root, scratch, files)
    done = specrail(scratch, *args)
    assert done.returncode == 0, done.stderr
    return scratch


def uri(root: Path, path: str) -> str:
    return (root / path).as_uri()


def path_of(root: Path, document: str) -> str:
    """The project path of the file at URI `document`."""
    return Path(unquote(urlparse(document).path)).relative_to(root).as_posix()


def units(text: str, encoding: str) -> int:
    """How many columns `text` takes in `encoding`."""
    if encoding == types.PositionEncodingKind.Utf8:
        return len(text.encode("utf-8"))
    if encoding == types.PositionEncodingKind.Utf16:
        return len(text.encode("utf-16-le")) // 2
    return len(text)


def position(text: str, needle: str, encoding: str, *, after: bool = False) -> types.Position:
    """Where `needle` first starts in `text`, or where it ends."""
    at = text.index(needle) + (len(needle) if after else 0)
    start = text.rfind("\n", 0, at) + 1
    return types.Position(line=text.count("\n", 0, at), character=units(text[start:at], encoding))


def line_end(text: str, needle: str, encoding: str) -> types.Position:
    """The end of the line on which `needle` first starts."""
    at = text.index(needle)
    end = text.find("\n", at)
    return position(text, text[at : len(text) if end < 0 else end], encoding, after=True)


def offset(text: str, at: types.Position, encoding: str) -> int:
    """The index in `text` of position `at`."""
    lines = text.split("\n")
    if at.line >= len(lines):
        return len(text)
    start = sum(len(line) + 1 for line in lines[: at.line])
    counted = 0
    for i, char in enumerate(lines[at.line]):
        if counted >= at.character:
            return start + i
        counted += units(char, encoding)
    return start + len(lines[at.line])


def apply(text: str, edits: list[types.TextEdit], encoding: str) -> str:
    """`text` with `edits` made, as an editor makes them."""
    spans = [
        (offset(text, e.range.start, encoding), offset(text, e.range.end, encoding), e.new_text)
        for e in edits
    ]
    for start, end, new in sorted(spans, key=lambda s: s[0], reverse=True):
        text = text[:start] + new + text[end:]
    return text


def apply_workspace(
    root: Path, edit: types.WorkspaceEdit, encoding: str, texts: dict[str, str] | None = None
) -> dict[str, str]:
    """Each file `edit` changes, by project path, with its new text. Files
    are read from `texts` first, as an editor reads open documents first."""
    assert edit.document_changes is None, "specrail sends plain changes"
    changed = {}
    for document, edits in (edit.changes or {}).items():
        path = path_of(root, document)
        current = (texts or {}).get(path)
        changed[path] = apply(read(root, path) if current is None else current, edits, encoding)
    return changed
