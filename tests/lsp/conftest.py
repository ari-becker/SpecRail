"""Each test runs once for each editor whose client pytest-lsp can play: the
server is started and initialized with that editor's capabilities, in a new
project of its own."""

from collections.abc import AsyncGenerator
from pathlib import Path

import pytest
import pytest_lsp
from lsprotocol import types
from pygls.protocol import default_converter
from pytest_lsp import ClientServerConfig, LanguageClient, client_capabilities
from pytest_lsp.client import register_lsp_features

import support

#: The editors, as pytest-lsp names their recorded capabilities, and the
#: position encoding each one ends up with: VS Code and Neovim 0.10 offer
#: only UTF-16; Neovim 0.11 and Emacs offer UTF-8 too.
EDITORS = {
    "visual_studio_code@v1.65.2": types.PositionEncodingKind.Utf16,
    "neovim@v0.10.0": types.PositionEncodingKind.Utf16,
    "neovim@v0.11.0": types.PositionEncodingKind.Utf8,
    "emacs@v29.1": types.PositionEncodingKind.Utf8,
}


class EditorClient(LanguageClient):
    """pytest-lsp's client, which also answers `client/registerCapability`
    as an editor does, keeping what the server registered."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.registrations: list[types.Registration] = []
        self.editor = ""
        self.encoding = types.PositionEncodingKind.Utf16
        self.root = Path()
        #: The text of each document the test opened, by project path.
        self.texts: dict[str, str] = {}
        self.versions: dict[str, int] = {}

    def doc(self, path: str) -> types.TextDocumentIdentifier:
        return types.TextDocumentIdentifier(uri=support.uri(self.root, path))

    def open(self, path: str, text: str | None = None) -> str:
        """Opens the document at `path`, with `text` in place of what is on
        disk when given, and returns its text."""
        text = support.read(self.root, path) if text is None else text
        self.texts[path] = text
        self.versions[path] = 1
        item = types.TextDocumentItem(
            uri=support.uri(self.root, path), language_id="markdown", version=1, text=text
        )
        self.text_document_did_open(types.DidOpenTextDocumentParams(text_document=item))
        return text

    def change(self, path: str, text: str) -> None:
        """Replaces the whole text of the open document at `path`."""
        self.texts[path] = text
        self.versions[path] += 1
        document = types.VersionedTextDocumentIdentifier(
            uri=support.uri(self.root, path), version=self.versions[path]
        )
        whole = types.TextDocumentContentChangeWholeDocument(text=text)
        self.text_document_did_change(
            types.DidChangeTextDocumentParams(text_document=document, content_changes=[whole])
        )

    def at(self, path: str, needle: str, *, after: bool = False) -> dict:
        """The document and position where `needle` starts, or ends, in it,
        as the fields of a request's parameters."""
        text = self.texts.get(path) or support.read(self.root, path)
        where = support.position(text, needle, self.encoding, after=after)
        return {"text_document": self.doc(path), "position": where}

    async def settle(self) -> None:
        """Waits until the server has handled everything sent so far, and the
        client everything the server sent back: the server answers in order."""
        await self.text_document_hover_async(
            types.HoverParams(
                text_document=self.doc("specs/a.spec.md"),
                position=types.Position(line=0, character=0),
            )
        )


def register_capability(client: EditorClient, params: types.RegistrationParams) -> None:
    client.registrations.extend(params.registrations)


def make_client() -> EditorClient:
    client = EditorClient(converter_factory=default_converter)
    register_lsp_features(client)
    client.feature(types.CLIENT_REGISTER_CAPABILITY)(register_capability)
    return client


@pytest.fixture
def project(request: pytest.FixtureRequest, tmp_path: Path) -> Path:
    """A new project, with the changes a `files` mark names."""
    root = tmp_path / "project"
    root.mkdir()
    mark = request.node.get_closest_marker("files")
    support.make_project(root, mark.args[0] if mark else {})
    return root


def pytest_addoption(parser: pytest.Parser) -> None:
    described = "the specrail executable to test; zig-out/bin/specrail by default"
    parser.addoption("--specrail", help=described)


def pytest_configure(config: pytest.Config) -> None:
    given = config.getoption("--specrail")
    if given:
        support.SPECRAIL = str(Path(given).resolve())


class Server(ClientServerConfig):
    """The server under test: whichever specrail `--specrail` names, known
    only once pytest has read its options."""

    def get_server_command(self, devtools: str | None = None) -> list[str]:
        self.server_command = [support.SPECRAIL, "lsp"]
        return super().get_server_command(devtools)


CONFIG = Server(server_command=[], client_factory=make_client, server_env=support.ENV)


@pytest_lsp.fixture(config=CONFIG, params=list(EDITORS))
async def client(
    request: pytest.FixtureRequest, lsp_client: EditorClient, project: Path
) -> AsyncGenerator[None]:
    lsp_client.editor = request.param
    lsp_client.root = project
    folder = types.WorkspaceFolder(uri=project.as_uri(), name="project")
    result = await lsp_client.initialize_session(
        types.InitializeParams(
            capabilities=client_capabilities(request.param),
            root_uri=project.as_uri(),
            workspace_folders=[folder],
        )
    )
    lsp_client.encoding = result.capabilities.position_encoding
    yield
    await lsp_client.shutdown_session()
