A reference is a single line in a test that claims a leaf section: the test
next to it verifies that section. References are written to be found with
`rg`. One line carries the whole address, so `rg 'login.spec.md § 1.1.2'`
finds every test of a section and `rg 'specrail: specs/auth/'` finds every
test of a directory of specs. A test that verifies several sections carries
one line for each.

```zig
// specrail: specs/auth/login.spec.md § 1.1.2 Accept password login
// specrail: specs/auth/sessions.spec.md § 2.1 Create session
test "password login creates a session" { ... }
```

---

# § 1 Syntax
```toml
status = "planned"
```

## § 1.1 Reference line

A reference MUST be a line of the form
`<prefix>specrail: <path> § <number> <title>`, where `<path>` is the path of a
spec file relative to the project root with `/` separators, and `<number>` and
`<title>` follow the section heading syntax in
`specs/format/spec-files.spec.md`.

## § 1.2 Comment prefix

specrail MUST treat a line as a reference only when the text before
`specrail:` consists solely of whitespace and the characters `/ * # - ; % ! < ( {`.
This admits the comment markers of most languages (`//`, `#`, `--`, `;`, `%`,
`/*`, `<!--`, `(*`, `{-`) and excludes string literals and Zig multiline
strings (`\\`), which is where test fixtures for reference syntax live.

## § 1.3 Block comment closers

specrail MUST remove a trailing `*/`, `-->`, `*)` or `-}`, and any whitespace
before it, from a reference's title before matching it.

## § 1.4 Malformed references

check MUST report as an error a line that has a valid prefix and `specrail:`
but does not otherwise match the reference syntax, so that a mistyped
reference cannot silently fail to count.

# § 2 Scanning
```toml
status = "planned"
```

References are found by a plain line scan, the same way an agent finds them
with `rg`. No programming language is parsed.

## § 2.1 Scanned files

specrail MUST scan for references every file found by the file scan, except
files under the spec root, files matching an `exclude` pattern in
`specrail.toml`, and binary files.

## § 2.2 Binary files

specrail MUST treat a file as binary when its first 8000 bytes contain a NUL
byte.

## § 2.3 Line endings

specrail MUST accept both `\n` and `\r\n` line endings, and MUST NOT include a
`\r` in a parsed title.

# § 3 Matching
```toml
status = "planned"
```

A reference matches a section when its path names the section's spec file and
both its number and its title equal the section's. Anything less is reported,
so drift between specs and tests is never silent.

## § 3.1 Dangling references

check MUST report a reference as dangling when its path names no spec file,
or when its spec file has neither a section with its number nor a section with
its title.

## § 3.2 Stale references

check MUST report a reference as stale when its spec file has a section with
its number but a different title, or a section with its title but a different
number. The diagnostic MUST show the current heading of each such section, so
an agent can fix the reference without opening the spec.

## § 3.3 References name leaves

check MUST report a reference to a parent section as an error.
