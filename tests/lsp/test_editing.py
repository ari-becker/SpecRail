"""Diagnostics and edits. Each edit the server returns is applied the way an
editor applies it, in the encoding the editor settled on, and the result
compared with what the CLI does to a copy of the project."""

import re
from pathlib import Path

import pytest
from lsprotocol import types

import support
from conftest import EditorClient

SEVERITIES = {
    "error": types.DiagnosticSeverity.Error,
    "warning": types.DiagnosticSeverity.Warning,
    "note": types.DiagnosticSeverity.Information,
}


def cli_diagnostics(root: Path, path: str, encoding: str) -> list[tuple]:
    """What `specrail check` reports in the file at `path`, as LSP has it."""
    lines = support.read(root, path).split("\n")
    found = []
    for line in support.specrail(root, "check").stdout.splitlines():
        m = re.match(r"(.+?):(\d+):(\d+): (\w+): (.*)", line)
        if not m or m[1] != path:
            continue
        text = lines[int(m[2]) - 1]
        before = text.encode("utf-8")[: int(m[3]) - 1].decode("utf-8")
        start = types.Position(line=int(m[2]) - 1, character=support.units(before, encoding))
        end = types.Position(line=int(m[2]) - 1, character=support.units(text, encoding))
        found.append((start, end, SEVERITIES[m[4]], m[5]))
    return found


def lsp_diagnostics(client: EditorClient, path: str) -> list[tuple]:
    diagnostics = client.diagnostics[support.uri(client.root, path)]
    return [(d.range.start, d.range.end, d.severity, d.message) for d in diagnostics]


# specrail: specs/lsp.spec.md § 1.2 Live index
# specrail: specs/lsp.spec.md § 3.1 Diagnostics
async def test_open_documents_get_check_s_diagnostics_as_they_change(
    client: EditorClient, tmp_path: Path
):
    client.open("src/t.py")
    a = client.open("specs/a.spec.md")
    await client.settle()
    assert lsp_diagnostics(client, "src/t.py") == []
    # Retitling a section, unsaved, makes the test file's reference stale.
    retitled = a.replace("§ 1.1 Password", "§ 1.1 Passphrase")
    client.change("specs/a.spec.md", retitled)
    await client.settle()
    copy = support.copy(client.root, tmp_path / "copy", {"specs/a.spec.md": retitled})
    for path in ["src/t.py", "specs/a.spec.md"]:
        assert lsp_diagnostics(client, path) == cli_diagnostics(copy, path, client.encoding)
    assert "stale reference" in lsp_diagnostics(client, "src/t.py")[0][3]


def renamed_by_cli(client: EditorClient, scratch: Path, old: str, new: str) -> dict[str, str]:
    """Each file `specrail mv old new` changes, with its new text."""
    copy = support.as_cli_would(client.root, scratch, "mv", old, new)
    # mv left no reference behind, so the comparison is with a correct result.
    out = support.specrail(copy, "check").stdout
    assert "stale" not in out and "dangling" not in out
    changed = [p for p in support.PROJECT if support.read(copy, p) != support.read(client.root, p)]
    return {p: support.read(copy, p) for p in changed}


KEY = "specs/a.spec.md § 1.2 Café 🔑"
NEW_KEY = "specs/a.spec.md § 1.2 Clé 🗝"


# specrail: specs/lsp.spec.md § 3.2 Rename
@pytest.mark.parametrize(
    ("path", "needle"),
    [("specs/a.spec.md", "Café"), ("src/t.py", "Café"), ("specs/b.spec.md", "Café")],
    ids=["heading", "reference", "dependency"],
)
async def test_rename_does_what_mv_does(
    client: EditorClient, tmp_path: Path, path: str, needle: str
):
    client.open(path)
    prepared = await client.text_document_prepare_rename_async(
        types.PrepareRenameParams(**client.at(path, needle))
    )
    assert isinstance(prepared, types.PrepareRenamePlaceholder)
    assert prepared.placeholder == "Café 🔑"
    text = client.texts[path]
    start = support.offset(text, prepared.range.start, client.encoding)
    end = support.offset(text, prepared.range.end, client.encoding)
    assert "Café 🔑" in text[start:end]

    edit = await client.text_document_rename_async(
        types.RenameParams(**client.at(path, needle), new_name="Clé 🗝")
    )
    assert edit is not None
    changed = support.apply_workspace(client.root, edit, client.encoding)
    assert changed == renamed_by_cli(client, tmp_path / "copy", KEY, NEW_KEY)


SLOPPY = support.A_SPEC.replace("## § 1.1 Password", "##   §  1.1   Password  ").replace(
    'x-owner = "auth"', 'x-owner="auth"'
)


# specrail: specs/lsp.spec.md § 3.3 Formatting
async def test_formatting_does_what_fmt_does(client: EditorClient, tmp_path: Path):
    client.open("specs/a.spec.md", SLOPPY)
    edits = await client.text_document_formatting_async(
        types.DocumentFormattingParams(
            text_document=client.doc("specs/a.spec.md"),
            options=types.FormattingOptions(tab_size=4, insert_spaces=True),
        )
    )
    assert edits
    copy = support.as_cli_would(
        client.root, tmp_path / "copy", "fmt", files={"specs/a.spec.md": SLOPPY}
    )
    expected = support.read(copy, "specs/a.spec.md")
    assert expected != SLOPPY
    assert support.apply(SLOPPY, edits, client.encoding) == expected


OUT_OF_ORDER = {
    "specs/a.spec.md": support.A_SPEC.replace("§ 1.1 Password", "§ 1.3 Password"),
    "src/t.py": support.reference_lines(["specs/a.spec.md § 1.3 Password", KEY]),
}


# specrail: specs/lsp.spec.md § 3.4 Renumber action
@pytest.mark.files(OUT_OF_ORDER)
async def test_the_renumber_action_does_what_fmt_does(client: EditorClient, tmp_path: Path):
    text = client.open("specs/a.spec.md")
    whole = types.Range(
        start=types.Position(line=0, character=0),
        end=types.Position(line=text.count("\n"), character=0),
    )
    actions = await client.text_document_code_action_async(
        types.CodeActionParams(
            text_document=client.doc("specs/a.spec.md"),
            range=whole,
            context=types.CodeActionContext(diagnostics=[]),
        )
    )
    assert actions is not None
    assert [a.title for a in actions] == ["Renumber sections by position"]
    action = actions[0]
    assert isinstance(action, types.CodeAction)
    assert action.edit is not None
    changed = support.apply_workspace(client.root, action.edit, client.encoding)
    copy = support.as_cli_would(client.root, tmp_path / "copy", "fmt")
    expected = {
        p: support.read(copy, p)
        for p in support.PROJECT
        if support.read(copy, p) != support.read(client.root, p)
    }
    assert changed == expected
    assert "§ 1.1 Password" in changed["specs/a.spec.md"]


# specrail: specs/lsp.spec.md § 3.5 File renames
async def test_moving_a_spec_file_does_what_mv_does(client: EditorClient, tmp_path: Path):
    old, new = "specs/a.spec.md", "specs/auth/a.spec.md"
    move = types.FileRename(
        old_uri=support.uri(client.root, old), new_uri=support.uri(client.root, new)
    )
    edit = await client.workspace_will_rename_files_async(types.RenameFilesParams(files=[move]))
    assert edit is not None
    # The editor makes the edit before it moves the file.
    changed = support.apply_workspace(client.root, edit, client.encoding)
    copy = support.as_cli_would(client.root, tmp_path / "copy", "mv", old, new)
    assert changed == {p: support.read(copy, p) for p in changed}
    assert sorted(changed) == ["specs/b.spec.md", "src/t.py"]


SESSIONS = {
    "specs/auth/c.spec.md": "# § 1 Sessions\n\nIt MUST expire.\n",
    "src/u.py": support.reference_lines(["specs/auth/c.spec.md § 1 Sessions"]),
}


# specrail: specs/lsp.spec.md § 3.5 File renames
@pytest.mark.files(SESSIONS)
async def test_moving_a_directory_does_what_mv_does(client: EditorClient, tmp_path: Path):
    old, new = "specs/auth", "specs/identity"
    move = types.FileRename(
        old_uri=support.uri(client.root, old), new_uri=support.uri(client.root, new)
    )
    edit = await client.workspace_will_rename_files_async(types.RenameFilesParams(files=[move]))
    assert edit is not None
    changed = support.apply_workspace(client.root, edit, client.encoding)
    copy = support.as_cli_would(client.root, tmp_path / "copy", "mv", old, new)
    assert changed == {"src/u.py": support.read(copy, "src/u.py")}
