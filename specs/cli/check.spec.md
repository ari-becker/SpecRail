`specrail check` is the signal an agent hill-climbs against: while it fails,
the specs and the tests disagree. It reads every spec file and scanned source
file, and in one pass reports every error the format specs define. It never
runs tests.

---

# § 1 Coverage

## § 1.1 Uncovered leaves

check MUST report an error at the heading of each leaf whose effective status
is `done` and that no reference names.

## § 1.2 Unfinished leaves

check MUST NOT require references to a leaf whose effective status is
`planned` or `in-progress`, and MUST accept references to such a leaf, so
tests can be written before the code.

# § 2 Scope

## § 2.1 Whole project

`specrail check` with no arguments MUST report every error in the project in
one run, rather than stopping at the first.

## § 2.2 Selected specs

Given paths of spec files or directories under the spec root, check MUST
report only diagnostics located in those spec files, plus diagnostics for
references and dependency entries that name sections in them.

# § 3 Report

check's output is its diagnostics. Unfinished work stays visible in it
without failing the build, and is listed once per declaration rather than
once per leaf, so a large planned subtree costs one line.

## § 3.1 Diagnostic lines

check MUST print its diagnostics to stdout as diagnostic lines.

## § 3.2 Stable order

check MUST sort its diagnostics by path, then line, then column, so its output
is identical across runs on unchanged input.

## § 3.3 Unfinished work

check MUST print a note at the heading of each section whose own metadata
block sets `status` to `planned` or `in-progress`, giving the status and any
`due`, `assigned` and `assigned-until` values. Sections that only inherit a
status MUST NOT get a note.

## § 3.4 Overdue work

A note for a section MUST say that the section is overdue once its `due` date
has ended everywhere on Earth: at the end of that date in UTC−12, which is
noon UTC on the following day. Every machine then gives the same answer,
whatever its time zone.

## § 3.5 Expired claims

check MUST print a note at the heading of each section whose `assigned-until`
is earlier than the current time, saying that its claim has expired and naming
the assignee.

## § 3.6 Summary line

check MUST end its text output with one line giving the numbers of errors and
warnings, the number of covered `done` leaves out of all `done` leaves, and
the numbers of `planned` and `in-progress` leaves.

## § 3.7 JSON output

Given `--json`, check MUST instead print a single JSON object holding a
`diagnostics` array, in the same order as the text output, whose elements
have `path`, `line`, `column`, `severity` and `message` fields, and a
`summary` object.

## § 3.8 JSON summary

Given `--json`, the `summary` object MUST contain the integer fields `errors`,
`warnings`, `done_leaves`, `covered_leaves`, `planned_leaves` and
`in_progress_leaves`.

# § 4 Exit status

## § 4.1 Pass and fail

check MUST exit with status 0 when it reports no errors and with status 1
otherwise. Warnings and notes, including overdue and expired-claim notes, MUST
NOT change the exit status.

## § 4.2 Warnings as errors

Given `--warnings-as-errors`, check MUST report every warning as an error,
count it among the errors, and exit with status 1 when there are any.
