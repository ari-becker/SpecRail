A spec file's path, relative to the project root, is its identity. A spec file
has up to two parts: context, which explains, and sections, which hold the
requirements. This paragraph is this file's context, and the `---` below
separates it from the sections.

A spec file can also be the parent of a directory. `specs/auth.spec.md` is the
parent file of `specs/auth/`, so its context is context for every spec under
that directory, the way a section's own prose is context for its children.

---

# § 1 Discovery

## § 1.1 Spec files

specrail MUST treat a file found by the file scan as a spec file exactly when
it is under the spec root and its name ends in `.spec.md`.

## § 1.2 Parent files
```toml
status = "planned"
```

specrail MUST treat a spec file named `<name>.spec.md` as the parent file of
the directory `<name>` beside it, and `root.spec.md` directly in the spec root
as the parent file of the spec root.

## § 1.3 Ancestor files
```toml
status = "planned"
```

The ancestor files of a spec file MUST be the parent files of the directories
that contain it, from the spec root inward, excluding the spec file itself,
skipping directories without a parent file, and listing each file once.

## § 1.4 Other files under the spec root

specrail MUST ignore files under the spec root whose names do not end in
`.spec.md`, so that specs can sit next to images and other assets.

# § 2 Context and sections

The boundary between context and sections is an explicit Markdown thematic
break, not a guess. Context can then use headings of any level, and a mistyped
section heading is reported instead of quietly becoming context.

## § 2.1 Separator

A spec file's separator MUST be the first line outside fenced code blocks that
consists of `---`, optionally followed by whitespace, and follows a blank
line. Everything before the separator is the file's context, and everything
after it is the file's sections.

## § 2.2 Files without a separator

A spec file without a separator MUST be entirely context when it has no
section headings, and entirely sections otherwise.

## § 2.3 Content before the first section

check MUST report an error when non-blank content comes before the first
section heading in a file's sections, saying that a separator is missing or
misplaced.

## § 2.4 Empty context

check MUST report a separator with no non-blank content before it as an
error. Such a separator separates nothing, and on a file's first line GitHub
reads `---` as the start of YAML front matter.

## § 2.5 Later thematic breaks

specrail MUST treat `---` lines after the separator as ordinary prose.

## § 2.6 Section headings in context

check MUST report as an error a heading in a file's context whose text starts
with `§`, or with `%` followed by a space and a digit, because it is almost
certainly a section heading on the wrong side of the separator.

# § 3 Headings

Heading recognition is deliberately narrower than CommonMark. specrail only
needs to find section boundaries, and a narrow rule is easier for agents to
follow and lets a line scanner stand in for a Markdown parser.

## § 3.1 Fenced code blocks

A line indented by at most three spaces that starts with three or more
backticks or tildes MUST open a fenced code block. The block MUST close at the
next line that consists only of at least as many of the same character,
optionally followed by whitespace. specrail MUST NOT recognize headings,
separators, metadata blocks or requirement keywords inside a fenced code
block.

## § 3.2 Heading lines

Outside fenced code blocks, specrail MUST treat a line that starts with one to
six `#` characters followed by a space as a heading.

## § 3.3 Setext headings

check MUST report as an error every setext heading underline, as CommonMark
defines it, outside fenced code blocks. GitHub renders the line above such an
underline as a heading that specrail would not see.

## § 3.4 Section heading syntax

Every heading in a file's sections MUST have the form
`<hashes> § <number> <title>`, where `<number>` is one or more positive
decimal integers without leading zeros joined by `.`, and `<title>` is not
empty. check MUST report any other heading in a file's sections as an error.

## § 3.5 Heading level equals depth

The number of `#` characters in a section heading MUST equal the number of
components in its section number (`# § 2`, `## § 2.3`, `### § 2.3.1`), which
limits specs to six levels. check MUST report a mismatch as an error.

## § 3.6 Section tree

specrail MUST derive the tree of sections from heading levels in document
order: a section's parent is the nearest preceding section whose heading is
one level higher. check MUST report as errors a first section heading that is
not level 1 and a heading more than one level deeper than the heading before
it.

## § 3.7 Title comparison

Wherever specrail compares titles (in references, dependency entries and
command arguments), it MUST compare them byte for byte after removing leading
and trailing whitespace.

# § 4 Numbering

Numbers follow position and are maintained by `specrail fmt`. An author or
agent can insert a section anywhere with any number and let the tool renumber
it, the sections after it, and every reference to them.

## § 4.1 Contiguous numbering

Within each file, top-level sections MUST be numbered 1, 2, 3, ... in document
order, and the children of section N MUST be numbered N.1, N.2, N.3, ... in
document order. check MUST report every section whose number differs from the
number implied by its position.

## § 4.2 Duplicate headings

check MUST report as an error two sections in one file with the same number
and the same title, because no reference can tell them apart.

# § 5 Prose

Requirements live only in leaves, so every requirement is something a test can
claim. Everything above a leaf is context: it explains, but it does not
demand.

## § 5.1 Requirements only in leaves

check MUST report an error for each requirement keyword in context prose: a
spec file's context and the own prose of a parent section.

## § 5.2 Keyword recognition

specrail MUST recognize a requirement keyword only as one of `MUST`,
`REQUIRED`, `SHALL`, `SHOULD`, `RECOMMENDED`, `MAY` and `OPTIONAL`, written in
uppercase as a whole word, outside fenced code blocks, inline code spans and
heading lines. The negated forms (`MUST NOT`, `NOT RECOMMENDED`, ...) each
contain one of these words.

## § 5.3 Leaves state requirements

check MUST report an error for each leaf whose effective status is `done` and
whose own prose contains no requirement keyword, saying to either state the
requirement with a keyword or move the text into context.

## § 5.4 Unfinished leaves without requirements

check MUST report a warning, with the same advice, for each leaf whose
effective status is `planned` or `in-progress` and whose own prose contains no
requirement keyword, so that rewording is not left until the code is already
finished.

# § 6 Section sign

Some keyboards and terminals make `§` hard or impossible to type. `%` stands
in for it on input, and `specrail fmt` turns it back into `§`, so committed
specs read the same for everyone. `%` was chosen because every major keyboard
layout types it without Option or AltGr, and it means nothing special to
shells, regular expressions, Markdown or TOML.

## § 6.1 Alternate section sign
```toml
status = "in-progress"
```

Wherever specrail reads a section sign (in section headings, reference lines,
dependency entries and command arguments), it MUST accept `%` in its place and
treat the two identically.

## § 6.2 Only in the marker position

specrail MUST treat `%` as a section sign only where a section sign belongs:
right after a heading's `#` characters, or right after the path in reference
form. A `%` anywhere else, such as in a title, MUST be treated as text.
