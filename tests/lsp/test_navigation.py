"""Moving between specs and tests: definition, references, hover and
completion, with every position counted in the encoding the editor settled
on."""

from lsprotocol import types

import support
from conftest import EditorClient

KEY = "## § 1.2 Café 🔑"


def location(found) -> types.Location:
    """The one location a definition request found."""
    if isinstance(found, list):
        assert len(found) == 1
        found = found[0]
    assert isinstance(found, types.Location)
    return found


# specrail: specs/lsp.spec.md § 2.1 Reference to section
async def test_a_reference_line_leads_to_its_heading(client: EditorClient):
    client.open("src/t.py")
    found = await client.text_document_definition_async(
        types.DefinitionParams(**client.at("src/t.py", "Café"))
    )
    heading = location(found)
    assert support.path_of(client.root, heading.uri) == "specs/a.spec.md"
    a = support.read(client.root, "specs/a.spec.md")
    assert heading.range.start == support.position(a, KEY, client.encoding)
    assert heading.range.end == support.line_end(a, KEY, client.encoding)


# specrail: specs/lsp.spec.md § 2.1 Reference to section
async def test_a_dependency_entry_leads_to_its_heading(client: EditorClient):
    client.open("specs/b.spec.md")
    found = await client.text_document_definition_async(
        types.DefinitionParams(**client.at("specs/b.spec.md", "🔑"))
    )
    heading = location(found)
    a = support.read(client.root, "specs/a.spec.md")
    assert support.path_of(client.root, heading.uri) == "specs/a.spec.md"
    assert heading.range.start == support.position(a, KEY, client.encoding)


# specrail: specs/lsp.spec.md § 2.2 Section to references
async def test_a_heading_leads_to_everything_naming_its_subtree(client: EditorClient):
    client.open("specs/a.spec.md")
    context = types.ReferenceContext(include_declaration=False)
    found = await client.text_document_references_async(
        types.ReferenceParams(**client.at("specs/a.spec.md", "Login"), context=context)
    )
    t = support.read(client.root, "src/t.py")
    b = support.read(client.root, "specs/b.spec.md")
    # A reference line is found from its marker, and a dependency entry from
    # its opening quote, each to the end of its line.
    marker = f"{support.MARKER} "
    expected = [
        ("specs/b.spec.md", '"specs/a.spec.md § 1.2 Café 🔑",', b),
        ("src/t.py", marker + support.REFERENCES[0], t),
        ("src/t.py", marker + support.REFERENCES[1], t),
    ]
    wanted = [
        (
            path,
            support.position(text, needle, client.encoding),
            support.line_end(text, needle, client.encoding),
        )
        for path, needle, text in expected
    ]
    got = [(support.path_of(client.root, r.uri), r.range.start, r.range.end) for r in found or []]
    assert sorted(got, key=lambda found: (found[0], found[1].line)) == wanted


# specrail: specs/lsp.spec.md § 2.3 Hover
async def test_hover_shows_the_named_section(client: EditorClient):
    client.open("src/t.py")
    found = await client.text_document_hover_async(
        types.HoverParams(**client.at("src/t.py", "Password"))
    )
    assert found is not None
    assert isinstance(found.contents, types.MarkupContent)
    assert found.contents.kind == types.MarkupKind.Markdown
    assert (
        found.contents.value
        == '## § 1.1 Password\n```toml\nx-owner = "auth"\n```\n\nIt MUST accept a password.'
    )


def edit_of(item: types.CompletionItem) -> types.TextEdit:
    assert isinstance(item.text_edit, types.TextEdit)
    return item.text_edit


# specrail: specs/lsp.spec.md § 2.4 Completion
async def test_completion_offers_paths_then_headings(client: EditorClient):
    typed = f"# {support.MARKER} specs/a"
    client.open("src/t.py")
    client.change("src/t.py", typed + "\n")
    found = await client.text_document_completion_async(
        types.CompletionParams(**client.at("src/t.py", typed, after=True))
    )
    items = found.items if isinstance(found, types.CompletionList) else found or []
    assert sorted(i.label for i in items) == ["specs/a.spec.md", "specs/b.spec.md"]
    # The editor filters by what was typed, and the edit replaces it.
    path = next(i for i in items if i.label == "specs/a.spec.md")
    assert (
        support.apply(typed, [edit_of(path)], client.encoding)
        == f"# {support.MARKER} specs/a.spec.md"
    )

    typed = f"# {support.MARKER} specs/a.spec.md § 1.2 Ca"
    client.change("src/t.py", typed + "\n")
    found = await client.text_document_completion_async(
        types.CompletionParams(**client.at("src/t.py", typed, after=True))
    )
    items = found.items if isinstance(found, types.CompletionList) else found or []
    labels = [i.label for i in items]
    assert labels == ["§ 1 Login", "§ 1.1 Password", "§ 1.2 Café 🔑"]
    key = items[2]
    expected = f"# {support.MARKER} specs/a.spec.md § 1.2 Café 🔑"
    assert support.apply(typed, [edit_of(key)], client.encoding) == expected


# specrail: specs/lsp.spec.md § 2.4 Completion
async def test_completion_in_a_dependency_entry_writes_the_section_sign(client: EditorClient):
    typed = '  "specs/a.spec.md % 1.1'
    b = support.read(client.root, "specs/b.spec.md").replace(
        '  "specs/a.spec.md § 1.2 Café 🔑', typed
    )
    client.open("specs/b.spec.md", b)
    found = await client.text_document_completion_async(
        types.CompletionParams(**client.at("specs/b.spec.md", typed, after=True))
    )
    items = found.items if isinstance(found, types.CompletionList) else found or []
    password = next(i for i in items if i.label == "§ 1.1 Password")
    completed = b.replace(typed, '  "specs/a.spec.md § 1.1 Password')
    assert support.apply(b, [edit_of(password)], client.encoding) == completed
