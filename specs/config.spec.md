`specrail.toml` marks the project root and names the spec root. It uses the
TOML subset described in `specs/format/metadata.spec.md`.

```toml
spec_root       = "specs"
exclude         = ["notes.md", "docs/**"]
claim_branch    = "main"
claim_max_hours = 8
```

---

# § 1 Project root
```toml
status = "planned"
```

## § 1.1 Finding the project root

specrail MUST use as the project root the nearest directory containing a file
named `specrail.toml`, starting at the working directory and moving up through
its parents.

## § 1.2 No project root

When no such directory exists, every command except `init`, `skill`,
`hook pre-receive` and `--help` MUST exit with status 2 and print to stderr an
error suggesting `specrail init`.

# § 2 Keys
```toml
status = "planned"
```

## § 2.1 Spec root

`spec_root` names the spec root relative to the project root. specrail MUST
exit with status 2 when `spec_root` is missing, is not a string, or does not
name a directory inside the project root.

## § 2.2 Exclude patterns

`exclude` is an optional array of glob patterns relative to the project root.
specrail MUST NOT scan a file for references when its path matches any of
them.

## § 2.3 Glob syntax

In an `exclude` pattern, `*` MUST match any run of characters other than `/`,
`**` MUST match any run of characters including `/`, `?` MUST match one
character other than `/`, and every other character MUST match itself.

## § 2.4 Claim branch

`claim_branch` is an optional string naming the branch that claims are pushed
to. specrail MUST use `main` when it is absent.

## § 2.5 Claim remote

`claim_remote` is an optional string naming the git remote that claims are
pushed to. specrail MUST use `origin` when it is absent.

## § 2.6 Maximum claim duration

`claim_max_hours` is an optional cap on how far ahead a claim's
`assigned-until` can be. specrail MUST exit with status 2 when it is present
and is not a positive integer.

## § 2.7 Unknown keys

specrail MUST exit with status 2 when `specrail.toml` contains any other key.

# § 3 File scan
```toml
status = "planned"
```

git already knows which files belong to the project, so specrail asks git
instead of reimplementing ignore rules.

## § 3.1 Listed files

specrail MUST consider exactly the files that
`git ls-files --cached --others --exclude-standard` lists when run in the
project root and that exist on disk: tracked files plus untracked files that
are not ignored.

## § 3.2 Without git

When the project root is not in a git work tree, or `git` cannot be run,
specrail MUST exit with status 2 and print the reason to stderr.
