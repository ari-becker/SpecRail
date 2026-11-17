`specrail swap` exchanges two sections, each with its subtree, in one
operation, and rewrites every reference and dependency entry to match. Where
`specrail mv` never overwrites a section, swap is how two sections trade
places. Sections are given in reference form, each quoted so it is a single
argument.

```sh
specrail swap 'specs/auth/login.spec.md § 2 Logout' \
              'specs/auth/login.spec.md § 3 Sessions'
```

---

# § 1 Sections

## § 1.1 Exchange

Given two sections in reference form, swap MUST put each section, with its
subtree and its title, where the other was, at the other's heading level. It
MUST renumber each file it changes by position, and rewrite every reference
and dependency entry naming a section whose heading changed.

## § 1.2 Across files

swap MUST exchange two sections in different spec files the same way as two
sections in one file.

## § 1.3 Sections must match

When either section does not exactly match a section, swap MUST change
nothing, print to stderr an error saying which one is stale or dangling, and
exit with status 1.

## § 1.4 Nested sections

swap MUST change nothing and exit with status 2 when both arguments name the
same section, or when one section lies inside the other's subtree.

# § 2 Safety

## § 2.1 Below the spec root

swap MUST change nothing and exit with status 2 when an argument is not a
section in reference form, or its path is absolute, contains a `..`
component, or does not lie below the spec root.

## § 2.2 Symbolic links

swap MUST NOT follow symbolic links. It MUST change nothing and exit with
status 2 when any part of the path of a file it would write, below the
project root, is a symbolic link.

## § 2.3 Unparseable files

swap MUST change nothing and exit with status 1 when a spec file it would
modify has errors that prevent building the file's section tree.

## § 2.4 Failed writes

swap MUST write the new content of every file it changes before it replaces
any file. When it cannot write one, it MUST change nothing and exit with
status 2.

## § 2.5 Report

swap MUST print to stdout the new address of each section in reference form,
the first argument's first, one per line, then the path of each file it
modified, one per line, and MUST print its errors to stderr.
