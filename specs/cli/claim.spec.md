`specrail claim` lets an agent take a section for a limited time, so agents
working in parallel do not implement the same requirement twice. A claim is a
commit pushed straight to the claim branch (`main` by default) that only sets
the section's `assigned` and `assigned-until`. git accepts a push only on top
of the commit it was built from, so when two agents claim at once, exactly one
push lands. The other agent fetches, sees the claim, and backs off.

Claims are optional. They exist for durable agents and autonomous software
factories, where many agents pick work from the same specs at once. An agent
that a person drives from a terminal has no need for them.

The work itself releases the claim: the agent starts its work branch from the
claim commit and removes the claim in the change that finishes the work. A
claim that is never released expires, and after that anyone can take the
section.

```sh
specrail claim 'specs/auth/login.spec.md § 1.1.1 Accept Google login' --for 2h --as agent-7
specrail release 'specs/auth/login.spec.md § 1.1.1 Accept Google login' --as agent-7
```

Assignee names are not authenticated. The claim protocol, and the hooks in
`specs/cli/hook.spec.md` that enforce it, prevent accidents between
cooperating agents, not abuse.

---

# § 1 Claiming

## § 1.1 Claim commit

`specrail claim <section> --for <duration>` MUST push to the claim branch on
the claim remote a commit that sets the section's `assigned` to the claimant
and its `assigned-until` to the current time plus `<duration>`, and changes
nothing else.

## § 1.2 Duration syntax

`<duration>` MUST be a positive integer followed by `m` for minutes or `h` for
hours, such as `90m` or `2h`.

## § 1.3 Claimant

claim MUST take the claimant's name from `--as <name>`, or otherwise from the
`SPECRAIL_ASSIGNEE` environment variable, and MUST exit with status 2 when
neither is set.

## § 1.4 Built on the remote branch

claim MUST fetch the claim branch and build its commit directly on the
fetched tip, reading the section from that commit and leaving the working
tree, the index and the current branch untouched.

## § 1.5 Unknown section

claim MUST change nothing and exit with status 1 when the section does not
match a section on the fetched tip, reporting it as stale or dangling as check
would.

## § 1.6 Conflicting claims

claim MUST change nothing and exit with status 1, naming the holder and the
expiry, when the section, one of its ancestor sections or one of its
descendants is held by a different assignee on the fetched tip, either by an
unexpired claim or by an assignment without `assigned-until`.

## § 1.7 Renewal

When the section already has an unexpired claim by the same assignee, claim
MUST replace its `assigned-until`, which renews the claim.

## § 1.8 Lost races

When the push is rejected because the claim branch has moved, claim MUST
fetch again and repeat its checks and its commit on the new tip, giving up
with status 1 after five attempts.

## § 1.9 Maximum duration

When `specrail.toml` sets `claim_max_hours`, claim MUST exit with status 2
without pushing when `<duration>` is longer than that.

## § 1.10 Commit message

claim MUST give its commit the subject `specrail claim <section>`, with the
section in reference form, so that `git log --grep` finds every claim of a
section.

## § 1.11 Identity and signing

claim MUST author and sign its commit as `git commit` would under the
repository's configuration.

## § 1.12 Output

On success, claim MUST print to stdout one line giving the pushed commit's id
and the claim's expiry, so the agent can start its work branch from that
commit. claim MUST print its errors to stderr.

# § 2 Releasing

Release is for giving up early. Finished work removes its claim in the change
that finishes it, without a separate commit.

## § 2.1 Release commit

`specrail release <section>` MUST push to the claim branch a commit that
removes the section's `assigned` and `assigned-until` and changes nothing
else. The commit MUST be built, retried and signed the same way as a claim
commit, with the subject `specrail release <section>`.

## § 2.2 Only the holder

release MUST change nothing and exit with status 1 when the section's claim
belongs to a different assignee, and MUST exit with status 0 without pushing
when the section has no claim.

## § 2.3 Output

On success, release MUST print the pushed commit's id to stdout, and it MUST
print its errors to stderr.
