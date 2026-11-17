---
name: specrail
description: Use in any repository with a specrail.toml. Its requirements live in numbered sections of *.spec.md files, and tests claim the requirements they verify with `specrail:` comment lines. Use it to work on a requirement, write tests that reference it, run `specrail check`, or write and edit specs.
---

# specrail

The requirements of this project live in specs: Markdown files ending in
`.spec.md` under the spec root that `specrail.toml` names (usually `specs/`).
Each requirement is a numbered leaf section, such as
`§ 1.1.2 Accept password login`. A test claims the leaf it verifies with a
one-line reference comment, and `specrail check` fails until every finished
leaf is claimed by a test and every reference still matches the heading it
names.

## Working on a section

1. Run `specrail context <path> § <number>` and read what it prints: the
   context of every spec file above the section, the section's ancestors, the
   section with its subsections, its dependencies, and the tests that already
   verify it. Given only a spec file, it prints an outline instead.
2. Implement the section.
3. Write tests. Above each test, add one comment line for each leaf it
   verifies, of the form `// specrail: <path> § <number> <title>`, with the
   path relative to the project root and the number and title copied exactly
   from the heading. Use the comment marker of the file's language, such as
   `//`, `#`, `--`, `;`, `%`, `/*` or `<!--`. Nothing but the comment marker
   may come before `specrail:` on the line.
4. When the section is finished, remove its `status`, or the status it
   inherits from an ancestor, so that it counts as done.
5. Run `specrail check` and fix what it reports, until it passes.

After adding, removing or reordering sections, run `specrail fmt`. It
renumbers sections by position and rewrites every reference and dependency
entry that names a renumbered section, so never renumber by hand. It also
normalizes headings and metadata blocks. To retitle or move a section, or to
move a spec file or a directory of specs, use `specrail mv`, giving sections
in reference form, each quoted as one argument: it rewrites every reference
and dependency entry to match. `specrail check` reports a reference that
nothing matches as dangling, and one where only the number or only the title
still matches as stale, and shows the current headings.

To find the tests of a section, search for its address, as in
`rg 'login.spec.md § 1.1.2'`. If you cannot type `§`, write `%` instead in
specs and references, and use `.` for it in an `rg` pattern.

## Reading specrail check

Each problem is one line: `path:line:column: severity: message`. Errors fail
the check. Warnings and notes do not, unless `--warnings-as-errors` is given.
Notes list unfinished work: the sections marked `planned` or `in-progress`,
with their due dates and assignees. `--json` prints one JSON object instead.
Given spec files or directories, check reports only on those, and on the
references and dependency entries that name them.

## The spec format

- A spec file has context first, then a line holding only `---` after a blank
  line, then numbered sections. A file with no sections needs no separator.
- A section heading is `#` characters, `§`, a number and a title. The number
  of `#` characters equals the number's depth: `# § 1 Login`,
  `## § 1.1 Providers`, `### § 1.1.1 Accept Google login`. Numbers follow
  position: top-level sections are 1, 2, 3, and so on, and the children of
  1.2 are 1.2.1, 1.2.2, and so on.
- Requirements live only in leaves, the sections without children, and are
  stated with the uppercase keywords of RFC 2119: MUST, MUST NOT, SHOULD,
  SHOULD NOT, MAY, REQUIRED and OPTIONAL. Context and the prose of parent
  sections explain, and never use those keywords in uppercase. A finished
  leaf without a keyword is an error, and an unfinished one a warning.
- A spec file `auth.spec.md` beside a directory `auth/` is that directory's
  parent file: its context applies to every spec under `auth/`. The spec
  root's `root.spec.md` applies to every spec.
- A metadata block is a fenced `toml` block directly after a heading:

  ```toml
  status       = "planned"
  due          = 2027-06-29
  assigned     = "someone"
  dependencies = [
    "specs/auth/sessions.spec.md § 2.1 Create session",
  ]
  ```

  `status` is `planned`, `in-progress` or `done`, and children inherit it. A
  section with no status, on itself or above it, is done, and a done leaf
  needs a test. `dependencies` name sections in the same form as test
  references, path first. Keys starting with `x-` are free for your own use.
  Comments are not allowed in metadata blocks.
