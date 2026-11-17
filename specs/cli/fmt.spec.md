`specrail fmt` puts spec files into canonical form. When section numbers
change, it keeps every reference and dependency entry pointing at the same
section. It never edits prose.

---

# § 1 Layout
```toml
status = "planned"
```

## § 1.1 Heading spacing

fmt MUST write each section heading as its `#` characters, a space, `§`, a
space, the number, a space and the title, with no trailing whitespace.

## § 1.2 Missing separator

When a spec file without a separator has non-blank content before its first
section heading, fmt MUST insert a blank line and a `---` line directly before
that heading, which turns the content into the file's context.

## § 1.3 Empty context

fmt MUST remove a separator that has no non-blank content before it.

## § 1.4 Section sign

fmt MUST replace each `%` used as a section sign with `§`, both in the section
headings of the spec files it formats and in the reference lines and
dependency entries that name those files, changing nothing else on the line.

# § 2 Renumbering
```toml
status = "planned"
```

Section numbers follow position. An author or agent inserting a section gives
it any number and runs fmt; the new section and every section after it get
their correct numbers, and references follow along.

## § 2.1 Renumber by position

fmt MUST rewrite every section number to the number implied by the section's
position, as defined in `specs/format/spec-files.spec.md`.

## § 2.2 Rewrite references

For every section whose heading fmt changes, fmt MUST rewrite each reference
and dependency entry in the project that matched the old number and title so
that it matches the new heading, changing nothing else on the line.

## § 2.3 Repair number drift

fmt MUST rewrite the number of a stale reference or dependency entry whose
title matches exactly one section in its spec file, so that it names that
section.

## § 2.4 Ambiguous headings

When a spec file has two sections with the same number and title, fmt MUST
NOT renumber that file or rewrite any reference to it, and MUST report an
error.

# § 3 Metadata blocks
```toml
status = "planned"
```

## § 3.1 Placement

fmt MUST remove blank lines between a section heading and its metadata
block.

## § 3.2 Key order

fmt MUST order keys as `status`, `due`, `assigned`, `assigned-until`,
`dependencies`, followed by extension keys in their original order.

## § 3.3 Alignment

fmt MUST pad keys with spaces so that every `=` in a block is in the same
column, one space after the longest key.

## § 3.4 Values

fmt MUST write strings as basic (double-quoted) strings and `dependencies` as
a multi-line array with one entry per line, each indented by two spaces and
followed by a comma. fmt MUST preserve the values of extension keys as
written.

## § 3.5 Redundant metadata

fmt MUST remove a `status = "done"` entry from a section whose effective
status would be `done` without it, and MUST remove a metadata block left with
no keys.

# § 4 Operation
```toml
status = "planned"
```

## § 4.1 Scope

`specrail fmt` with no arguments MUST format every spec file. Given paths of
spec files or directories, it MUST format only those spec files, but still
rewrite references and dependency entries naming them anywhere in the
project.

## § 4.2 Check mode

Given `--check`, fmt MUST write nothing, report each file it would change as
an error diagnostic, and exit with status 1 when any file would change.

## § 4.3 Untouched lines

fmt MUST leave every line it does not rewrite unchanged byte for byte,
including its line ending.

## § 4.4 Idempotence

Running fmt on its own output MUST change nothing.

## § 4.5 Unparseable files

fmt MUST NOT modify a spec file whose errors prevent it from building the
file's section tree or parsing a metadata block. It MUST report those errors
and exit with status 1.

## § 4.6 Diagnostic lines

fmt MUST print its diagnostics to stdout as diagnostic lines, sorted by path,
then line, then column.

## § 4.7 JSON output

Given `--check --json`, fmt MUST instead print a single JSON object holding a
`diagnostics` array with the same fields as `specrail check --json`, and a
`summary` object whose integer field `files` counts the files that would
change.
