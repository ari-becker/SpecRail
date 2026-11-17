# The spec format

A spec file is ordinary Markdown with strict rules for headings, so it reads
well on GitHub and can be parsed by a line scanner instead of a full Markdown
parser. specrail interprets only a few things in a spec file: the `---`
separator between context and sections, section headings, fenced code blocks
(so that headings and keywords inside examples are ignored), and the metadata
block directly after a section heading. Everything else is prose, and specrail
never rewrites it.

A complete example, `specs/auth/login.spec.md`:

````markdown
Login covers every way a user proves who they are. Sessions are specified in
`specs/auth/sessions.spec.md`.

---

# § 1 Login page

## § 1.1 Providers

### § 1.1.1 Accept Google login
```toml
status       = "planned"
due          = 2027-06-29
assigned     = "someone"
dependencies = [
  "specs/auth/sessions.spec.md § 2.1 Create session",
]
```

The login page MUST show a "Login with Google" button that, when pressed,
begins the Google login flow.

### § 1.1.2 Accept password login

The login page MUST accept an email address and a password.
````

A test anywhere in the repository claims a leaf with one line:

```zig
// specrail: specs/auth/login.spec.md § 1.1.2 Accept password login
test "password login is accepted" { ... }
```

Cross-references between spec files in prose name the file only, never a
section number: `specrail fmt`, `specrail mv` and `specrail swap` keep
references and dependency entries up to date, but they do not edit prose.

Where `§` is hard to type, write `%` instead, in headings, references,
dependency entries and command arguments alike. `specrail fmt` turns it back
into `§`. To search for `§` without typing it, use `.` in its place: `rg`
treats `.` as any one character, so `rg 'login.spec.md . 1.1.2'` finds it.
