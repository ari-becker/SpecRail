Agents learn the specrail workflow from a skill: a Markdown file of
instructions that an agent loads when it works with specs. The skill is
compiled into the binary so it always matches the installed version.
`specrail skill` prints it so it can be installed wherever a given agent looks
for skills, for example `.claude/skills/specrail/SKILL.md`.

Claims are optional. They exist for durable agents and autonomous software
factories, where many agents pick work from the same specs at once. An agent
that a person drives from a terminal does not claim: the person already knows
what it is working on. The `SPECRAIL_ASSIGNEE` environment variable marks the
difference. Whoever runs agents as a fleet sets it to each agent's name, and
`specrail claim` already uses it as the claimant.

---

# § 1 The skill

## § 1.1 Output

`specrail skill` MUST print the embedded skill to stdout as Markdown that
starts with the YAML front matter agent skills use, containing `name` and
`description`.

## § 1.2 Workflow

The skill MUST instruct the agent to run `specrail context` before working on
a section, to add a reference line to each test that verifies a leaf, to run
`specrail check` until it passes, and to use `specrail fmt` and `specrail mv`
instead of editing section numbers, titles or references by hand.

## § 1.3 When to claim
```toml
status = "planned"
```

The skill MUST tell the agent to claim sections only when the
`SPECRAIL_ASSIGNEE` environment variable is set or its user or operator asks
it to, and otherwise not to claim at all.

## § 1.4 How to claim
```toml
status = "planned"
```

For an agent that claims, the skill MUST instruct it to claim a section with
`specrail claim` before working on it, to start its work branch from the claim
commit, to renew the claim before it expires, and to remove the claim in the
change that finishes the work, or with `specrail release` when giving up.

## § 1.5 Claims held by others
```toml
status = "planned"
```

When a section the agent is about to work on has an unexpired claim by someone
else, the skill MUST tell an agent that claims to choose other work, and an
agent that does not claim to point the claim out to its user before starting.

## § 1.6 Writing specs

The skill MUST explain the spec format: parent files, the separator between
context and sections, section headings, requirements only in leaves,
uppercase requirement keywords, and metadata blocks.

## § 1.7 Safe to install

The skill MUST NOT contain a line that specrail reads as a reference, so that
installing it inside a project does not make `specrail check` fail there.
