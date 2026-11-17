# specrail

specrail is a command-line tool, written in Zig, that keeps natural-language
specs linked to the tests that prove them. It is built for AI agents first:
everything it reads and prints is designed to be found with `rg` and to cost
few tokens. It optimizes for ease of searching and reading, not ease of
writing.

This file is the root of the spec tree. Everything in it is context for every
spec in this repository.

## How the pieces fit

- A **spec** is prose organized into numbered sections (`§ 2.3.1`). Leaf
  sections hold the requirements, written with RFC 2119 keywords.
- A **test** proves a leaf by carrying a one-line reference comment that names
  the spec file and the section's full heading.
- `specrail check` fails while any finished leaf has no test, or while any
  reference has drifted from the heading it names. It is the signal an agent
  hill-climbs against.
- `specrail context` gives an agent exactly the text it needs for one section:
  the section, its ancestor sections, and the context of every spec file above
  it in the tree.
- `specrail claim` is for fleets of autonomous agents. It lets an agent take a
  section for a limited time by pushing a tiny commit to `main`, so agents
  working in parallel do not build the same thing twice. An agent that a person
  drives from a terminal does not need it.
- `specrail fmt`, `specrail mv`, `specrail swap` and the language server keep
  references correct as specs are renumbered, retitled, moved and reordered.

specrail never runs tests and never judges whether a test is good enough. It
only tracks that every requirement is claimed by at least one test.

## How specs are organized

Specs form one tree, from this file down to single requirements. A spec file
is the parent of the directory with the same name beside it, and an agent
reads each level's context before the level below it.

```
specs/
  root.spec.md        context for every spec (this file)
  auth.spec.md        parent of auth/: auth-wide context and requirements
  auth/
    login.spec.md     context for login, then sections § 1, § 1.1, § 1.1.1 ...
    sessions.spec.md
```

A spec file becomes a parent by gaining a directory beside it. The file does
not move, so references to its sections do not change.

## What specrail leaves out

Specs say what the product does. They do not record plans, tasks, scenarios,
decision logs or lessons. An agent makes its own plan for implementing a
section; if that plan diverges from what was wanted, the spec was not clear
enough and gets more detail. The history of plans is not worth keeping in the
repository. Given/When/Then is allowed in prose, but nothing requires it.

The one piece of coordination state specs hold is a claim: who is working on
a section, and until when. It is two lines of metadata, and it expires on its
own.

Links run one way: tests point at specs, and specs never list their tests. The
only kind of link is "this test verifies that section".

## Glossary

- **project root**: the directory containing `specrail.toml`.
- **spec root**: the directory named by `spec_root` in `specrail.toml`. Every
  spec lives under it.
- **spec file**: a file under the spec root whose name ends in `.spec.md`.
- **separator**: a `---` line, after a blank line, between a spec file's
  context and its sections.
- **context**: the part of a spec file before its separator, or the whole file
  when it has no sections. Context explains; it never holds requirements.
- **parent file**: a spec file `<name>.spec.md` beside a directory `<name>/`.
  Its context applies to every spec under that directory. `root.spec.md` in
  the spec root is the parent file of the whole tree.
- **ancestor files**: the parent files above a spec file, from `root.spec.md`
  inward.
- **section**: a heading of the form `§ <number> <title>` and everything up to
  the next heading.
- **leaf**: a section with no child sections. **parent section**: a section
  with at least one child.
- **own prose**: a section's text after its heading and metadata block, up to
  the next heading.
- **context prose**: a spec file's context and the own prose of a parent
  section.
- **metadata block**: an optional fenced `toml` block directly after a section
  heading that holds status and planning information.
- **effective status**: a section's status after inheritance from its
  ancestor sections.
- **reference form**: `<path> § <number> <title>`, the way a section is named
  everywhere: in test comments, dependency entries and command arguments.
  When `§` is hard to type, `%` can stand in for it.
- **reference**: a line in a source file, `specrail: ` followed by a section
  in reference form, which claims that the nearby test verifies that section.
- **covered**: a leaf named by at least one reference.

## Requirement keywords

Uppercase requirement keywords are interpreted as described in RFC 2119 and
RFC 8174: only the uppercase forms carry meaning, and a lowercase "must" or
"should" is plain English. Requirements live only in leaves, so context (like
this whole file) and the prose of parent sections are written in lowercase.
