`specrail context` prints, in one call, everything an agent should read
before working on a section: general context first, the section itself last.
The output is Markdown and can go into a prompt as it is.

```sh
specrail context specs/auth/login.spec.md § 1.1.1
specrail context 'specs/auth/login.spec.md § 1.1.1 Accept Google login'
specrail context specs/auth/login.spec.md
```

---

# § 1 Arguments
```toml
status = "planned"
```

## § 1.1 Section address

context MUST join its arguments with single spaces and accept the result in
reference form, `<path> § <number> <title>`, where the title MAY be omitted.

## § 1.2 Title check

When a title is given and the section at that number has a different title,
context MUST print nothing to stdout, print to stderr an error saying the
address is stale and giving the section's current heading, and exit with
status 1.

## § 1.3 Unknown section

When the path names no spec file or the number names no section, context MUST
print nothing to stdout, print to stderr an error naming the address, and
exit with status 1.

## § 1.4 Whole file

Given only a spec file path, context MUST print the context of each ancestor
file, the file's own context, and the heading of every section in the file,
without section prose or metadata blocks.

# § 2 Section output
```toml
status = "planned"
```

For a section, the output follows the hierarchy down from the spec root, so
an agent reads the reasons before the requirement.

## § 2.1 Ancestor files

context MUST first print the context of each of the spec file's ancestor
files, outermost first.

## § 2.2 File context

context MUST then print the spec file's own context.

## § 2.3 Ancestors

context MUST then print, for each ancestor of the section from the top-level
section down, its heading, metadata block and own prose, and nothing from its
other children.

## § 2.4 The section and its subtree

context MUST then print the section's heading, metadata block and own prose,
followed by its whole subtree when it is a parent.

## § 2.5 Source markers

context MUST precede each piece of text it prints with a line
`<!-- <path>:<line> -->` naming the file and the line the text starts on.

## § 2.6 Dependencies

context MUST then list the dependency entries declared by the section and its
ancestors, one per line in reference form, each followed by the dependency's
effective status, without the dependencies' text. An agent that needs one
runs `specrail context` on it.

## § 2.7 Verifying tests

context MUST finally list, as `<path>:<line>`, the location of every reference
to the section or to a leaf in its subtree.
