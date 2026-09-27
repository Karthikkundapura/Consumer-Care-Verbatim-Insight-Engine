# Agent Engineering Review Log

CCVIE uses AI coding agents for much of its implementation (see
`CLAUDE.md`). This log records how agent-generated changes get reviewed
before they merge. It is a capstone deliverable alongside
`project-architecture-proposal.md` and `CCVIE_Project_26_Workflow.md`.

## Process

```
Agent writes code
    ↓
Human reviews
    ↓
Tests / CI validate
    ↓
Approved changes are merged
```

An agent change is not "done" when the agent stops; it is done when a
human has reviewed it and CI has validated it. Record every *meaningful*
agent-generated change here — a schema change, a contract change, a new
retrieval query, a router/planner rule, anything that could be wrong in a
way tests do not automatically catch. Trivial or purely mechanical
changes (formatting, a rename with no behavior change) do not need an
entry.

**Do not fabricate entries.** Add a row only when a real agent-generated
change was actually reviewed. An empty table below a real PR is more
honest than an invented one.

## Entry format

Each row:

| Field | Meaning |
|---|---|
| Date | When the change was reviewed |
| Area | File(s) or layer touched (for example `router/plan_executor.py`, Layer 2) |
| Prompt / Instruction | What the agent was asked to do |
| Agent Change | What the agent actually produced |
| Review Finding | What the human reviewer found, if anything |
| Action Taken | Accepted as-is / fixed / rejected / re-prompted |
| Test / CI Evidence | Which test or CI run confirms the outcome |

Finding categories that are worth watching for, and should be recorded
here **only when they actually occur** (this list is guidance for
reviewers, not a checklist to fill in every row):

- Incorrect embedding dimension
- Incorrect SQL/query assumption
- Unsupported operation (outside the Query Planner's approved vocabulary)
- Incorrect contract change
- Hallucinated field/table
- Unsafe text-to-SQL approach
- Missing validation

## Log

| Date | Area | Prompt / Instruction | Agent Change | Review Finding | Action Taken | Test / CI Evidence |
|---|---|---|---|---|---|---|
| _(no entries yet — add one the first time an agent-generated change goes through review)_ | | | | | | |
