`specrail mv` is the refactoring command. It changes where a spec file or a
section lives, or what a section is called, and in the same operation
rewrites every reference and dependency entry to match. Sections are given in
reference form, each quoted so it is a single argument.

```sh
specrail mv specs/auth/login.spec.md specs/identity/login.spec.md
specrail mv 'specs/auth/login.spec.md § 1.1.1 Accept Google login' \
            'specs/auth/login.spec.md § 1.1.1 Accept Google sign-in'
specrail mv 'specs/auth/login.spec.md § 1.1.1 Accept Google login' \
            'specs/auth/sso.spec.md § 2.3 Accept Google login'
```

---

# § 1 Files and directories
```toml
status = "planned"
```

A parent file and its directory are one unit, so moving either one moves
both.

## § 1.1 Move a spec file

Given two spec file paths, mv MUST move the file, together with the directory
it is the parent file of when there is one, and rewrite the path in every
reference and dependency entry that names a moved file.

## § 1.2 Move a directory

Given a directory under the spec root and a new path under the spec root, mv
MUST move the directory, together with its parent file when there is one, and
rewrite the path in every reference and dependency entry that names a moved
file.

## § 1.3 Existing destination

mv MUST change nothing and exit with status 2 when any destination path, for
the file or directory named or for the one moving with it, already exists.

## § 1.4 Root file

mv MUST move `root.spec.md` in the spec root as an ordinary file, never
together with the spec root.

# § 2 Sections
```toml
status = "planned"
```

## § 2.1 Source must match

When the source does not exactly match a section, mv MUST change nothing,
print to stderr an error saying the source is stale or dangling, and exit
with status 1.

## § 2.2 Retitle

Given a destination with the same path and number as the source and a
different title, mv MUST change the section's title and rewrite every
reference and dependency entry naming it.

## § 2.3 Move a section

Given a destination with a different path or number, mv MUST remove the
section and its subtree from the source file and insert them in the
destination file so the section gets the destination number and title. It
MUST set the heading levels of the moved subtree to match its new depth,
renumber the sections after the removal and insertion points, and rewrite
every reference and dependency entry naming a section whose heading changed.

## § 2.4 Valid destination

mv MUST change nothing and exit with status 2 when the parent of the
destination number does not exist in the destination file, when the last
component of the destination number is more than one greater than that
parent's number of children, or when the destination lies inside the subtree
being moved.

## § 2.5 Moving to a new file

mv MUST create a destination spec file that does not exist, provided the
destination number is `1`.

# § 3 Safety
```toml
status = "planned"
```

## § 3.1 Unparseable files

mv MUST change nothing and exit with status 1 when a spec file it would modify
has errors that prevent building the file's section tree.

## § 3.2 Report

mv MUST print to stdout the path of each file it modified, one per line, and
MUST print its errors to stderr.
