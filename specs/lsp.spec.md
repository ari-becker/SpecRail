`specrail lsp` runs a Language Server Protocol server so editors can move
between specs and tests. The editor starts it once per workspace and it keeps
running, holding the project index in memory, so requests do not rescan the
repository.

---

# § 1 Lifecycle

## § 1.1 Transport

`specrail lsp` MUST serve LSP 3.17 over JSON-RPC on stdin and stdout, finding
the project root from the workspace root the way the CLI does from its
working directory.

## § 1.2 Live index

The server MUST update its index when an open document changes, using the
unsaved contents, and when the client reports that a file was created,
changed or deleted.

## § 1.3 Exit status

`specrail lsp` MUST exit with status 0 when the client sent a shutdown request
before the exit notification, and with status 1 otherwise, as the Language
Server Protocol requires.

## § 1.4 Position encoding

The server MUST use UTF-8 positions when the client lists `utf-8` among the
position encodings it supports, and otherwise MUST count columns in UTF-16
code units, as the Language Server Protocol requires. In UTF-8, `§` takes two
bytes; in UTF-16, one code unit.

## § 1.5 Without a project

When the workspace has no project root, the server MUST keep running, answer
every request with an empty result, and show the user one message saying
why, so that the editor does not restart it in a loop.

## § 1.6 Workspace folders

The server MUST serve the project of the client's first workspace folder, or
of its root when the client sends no workspace folders.

# § 2 Navigation

## § 2.1 Reference to section

Go to definition on a reference line or a dependency entry MUST return the
heading of the section it names.

## § 2.2 Section to references

Find references on a section heading MUST return every reference and
dependency entry naming that section or a section in its subtree.

## § 2.3 Hover

Hovering over a reference line or dependency entry MUST show the named
section's heading, metadata block and own prose.

## § 2.4 Completion

On a reference line after `specrail: `, or inside a `dependencies` entry,
completion MUST offer spec file paths, and after a path and a section sign
(`§` or `%`), the headings of that file's sections, inserted with `§`.

# § 3 Editing
```toml
status       = "planned"
dependencies = [
  "specs/cli/fmt.spec.md § 2 Renumbering",
  "specs/cli/mv.spec.md § 2 Sections",
]
```

Editing goes through the same code as `specrail fmt` and `specrail mv`, so the
editor and the command line never disagree.

## § 3.1 Diagnostics
```toml
status = "done"
```

The server MUST publish for each open document the diagnostics that check
would report in that document, and MUST publish them again for every open
document whenever a change to any file may have changed them.

## § 3.2 Rename

Rename on a section heading, on a reference line or on a dependency entry
MUST change the title of the section it names and return a workspace edit
that also rewrites every reference and dependency entry naming that section,
as `specrail mv` would.

## § 3.3 Formatting

Document formatting on a spec file MUST return the edits `specrail fmt` would
make to that file, except renumbering.

## § 3.4 Renumber action

When a spec file's numbering is out of order, the server MUST offer a code
action that renumbers the file and returns a workspace edit that also
rewrites the affected references and dependency entries, as `specrail fmt`
would.

## § 3.5 File renames

When the client is about to rename or move a spec file, or a directory that
holds spec files, the server MUST return a workspace edit that rewrites the
path in every reference and dependency entry naming a moved spec file, as
`specrail mv` would.
