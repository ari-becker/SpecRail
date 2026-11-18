"""Starting the server as each editor starts it: the encoding it settles on,
the project it serves, and the file watching it asks for."""

import pytest
from lsprotocol import types

import support
from conftest import EDITORS, EditorClient


# specrail: specs/lsp.spec.md § 1.1 Transport
# specrail: specs/lsp.spec.md § 1.4 Position encoding
async def test_the_encoding_is_the_one_the_editor_can_count(client: EditorClient):
    assert client.encoding == EDITORS[client.editor]


# specrail: specs/lsp.spec.md § 1.2 Live index
async def test_files_are_watched_where_the_editor_lets_servers_ask(client: EditorClient):
    capabilities = client.capabilities
    assert capabilities is not None
    watched = capabilities.workspace and capabilities.workspace.did_change_watched_files
    if not (watched and watched.dynamic_registration):
        # Registering a capability the client cannot take would break the
        # protocol, so the editor reports only saves.
        await client.settle()
        assert client.registrations == []
        return
    await client.settle()
    methods = [r.method for r in client.registrations]
    assert methods == [types.WORKSPACE_DID_CHANGE_WATCHED_FILES]
    # A section retitled on disk makes the open test file's reference stale.
    client.open("src/t.py")
    a = support.read(client.root, "specs/a.spec.md").replace("§ 1.1 Password", "§ 1.1 Passphrase")
    support.write(client.root, {"specs/a.spec.md": a})
    change = types.FileEvent(
        uri=support.uri(client.root, "specs/a.spec.md"), type=types.FileChangeType.Changed
    )
    client.workspace_did_change_watched_files(types.DidChangeWatchedFilesParams(changes=[change]))
    await client.settle()
    diagnostics = client.diagnostics[support.uri(client.root, "src/t.py")]
    assert ["stale reference" in d.message for d in diagnostics] == [True]


# specrail: specs/lsp.spec.md § 1.2 Live index
async def test_a_saved_file_is_read_again(client: EditorClient):
    client.open("src/t.py")
    a = support.read(client.root, "specs/a.spec.md").replace("§ 1.1 Password", "§ 1.1 Passphrase")
    support.write(client.root, {"specs/a.spec.md": a})
    saved = types.DidSaveTextDocumentParams(text_document=client.doc("specs/a.spec.md"))
    client.text_document_did_save(saved)
    await client.settle()
    diagnostics = client.diagnostics[support.uri(client.root, "src/t.py")]
    assert ["stale reference" in d.message for d in diagnostics] == [True]


# specrail: specs/lsp.spec.md § 1.5 Without a project
@pytest.mark.files({"specrail.toml": None})
async def test_without_a_project_the_server_says_why_once_and_answers_empty(client: EditorClient):
    client.open("src/t.py")
    found = await client.text_document_definition_async(
        types.DefinitionParams(**client.at("src/t.py", "§ 1.2"))
    )
    assert found is None
    assert len(client.messages) == 1
    assert client.messages[0].type == types.MessageType.Warning
