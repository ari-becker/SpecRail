A metadata block records planning information about one section. It is
optional: a section without one is finished, present in the product, and can
be tested against. Metadata is TOML, the same format as `specrail.toml`.

---

# § 1 Placement

## § 1.1 Recognizing a block

specrail MUST treat a fenced code block whose info string is exactly `toml` as
a section's metadata block when it is the first non-blank content after the
section's heading. Any other fenced code block, including a later `toml`
block, MUST be treated as prose.

# § 2 TOML subset

Metadata blocks and `specrail.toml` share one deliberately small subset of
TOML v1.0, so that a single hand-written parser serves the whole tool.

## § 2.1 Supported syntax

specrail MUST accept documents made of blank lines, `#` comments, and
`key = value` lines where the key is a bare key and the value is a basic
string, a literal string, an integer, a boolean, a local date such as
`2027-06-29`, an offset date-time such as `2026-11-17T16:00:00Z`, or an array
of such values. An array MAY span several lines and MAY end with a trailing
comma.

## § 2.2 Unsupported syntax

specrail MUST report any TOML outside the supported subset as an error naming
the construct and its line. This includes tables, inline tables, dotted keys,
quoted keys, multi-line strings, floats, local times, and date-times without
an offset, which machines in different time zones would read differently.

## § 2.3 Duplicate keys

specrail MUST report a key that appears twice in one document as an error.

## § 2.4 No comments in metadata blocks

check MUST report a comment inside a metadata block as an error, because
`specrail fmt` reorders keys and could not keep comments attached to them.
Extension keys can hold anything that would otherwise be a comment.

# § 3 Keys

## § 3.1 Known keys

A metadata block MUST accept the keys `status` (a string), `due` (a local
date), `assigned` (a string), `assigned-until` (an offset date-time) and
`dependencies` (an array of strings), and check MUST report a known key whose
value has the wrong type as an error.

## § 3.2 Extension keys

A metadata block MUST accept any key that starts with `x-`, with any supported
value, and specrail MUST NOT interpret it.

## § 3.3 Unknown keys

check MUST report any other key as an error, so that a misspelling such as
`stauts` is caught.

# § 4 Status

## § 4.1 Status values

`status` MUST be one of `planned`, `in-progress` or `done`, and check MUST
report any other value as an error.

## § 4.2 Effective status

A section's effective status MUST be its own `status` when it has one,
otherwise the `status` of its nearest ancestor that has one, otherwise `done`.
An explicit `done` lets a finished section sit under an unfinished parent.

# § 5 Assignment

`assigned` names who is working on a section. Paired with `assigned-until`, it
is a claim that lapses on its own, so an agent that crashes or stalls stops
blocking the section without anyone cleaning up after it. Without
`assigned-until`, it is an open-ended assignment, typically to a person.
Agents make and give up claims with `specrail claim` and `specrail release`
(see `specs/cli/claim.spec.md`).

## § 5.1 Expiry needs an assignee

check MUST report an error when a metadata block has `assigned-until` but no
`assigned`.

# § 6 Dependencies

Dependencies record that the work on one section waits on another. They are
scheduling information: `specrail context` lists them by heading, and check
keeps them pointing at real sections.

## § 6.1 Entry syntax

Each entry of `dependencies` MUST be a section in reference form,
`<path> § <number> <title>`.

## § 6.2 Targets

check MUST report dependency entries that are dangling or stale by the same
rules as references (see `specs/format/references.spec.md`). Unlike
references, dependency entries MAY name parent sections.

## § 6.3 Finished work does not wait on unfinished work

check MUST report an error when a section whose effective status is `done`
lists a dependency whose effective status is not `done`.
