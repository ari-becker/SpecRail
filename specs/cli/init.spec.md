`specrail init` sets up a project. Unlike most commands, it does not need an
existing `specrail.toml`.

---

# § 1 Initializing a project

## § 1.1 Create config

`specrail init` MUST create `specrail.toml` in the working directory with
`spec_root = "specs"`, and MUST create the `specs` directory when it does not
exist.

## § 1.2 Root file

`specrail init` MUST create `root.spec.md` in the spec root when it does not
exist. The file MUST hold only context explaining its purpose, so that
`specrail check` passes on the new project. git does not track empty
directories, and without this file a fresh clone would have no spec root at
all.

## § 1.3 Spec root option

Given `--spec-root <dir>`, `specrail init` MUST use `<dir>` in place of
`specs`.

## § 1.4 Already initialized

When `specrail.toml` already exists in the working directory, `specrail init`
MUST change nothing, print an error to stderr, and exit with status 2.
