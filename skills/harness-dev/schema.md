# Harness Shared Issue Schema

This is the canonical schema for Linear issues created by `/harness-design` and validated
by `/harness-dev`. Every issue **must** contain all five sections below before implementation
begins.

## Validation Rules

The `/harness-dev` quality gate applies these checks before starting implementation:

1. **Section presence:** Each of the five required sections must appear as a level-2 markdown
   heading. Pattern: `^## (Context|Acceptance Criteria|Architecture Notes|Dependencies|Scope Boundary)`
2. **Minimum content:** Each section must contain at least 20 characters of non-whitespace
   content below its heading.
3. **No bare placeholders:** Each line matching `^\[.*\]$` (bracket-wrapped placeholder
   text) is excluded from the non-whitespace character count for that section.
   This is the stricter variant chosen over pure length check to prevent template
   boilerplate from passing validation (resolves design doc Reviewer Concern #2).

If any section fails, `/harness-dev` outputs a checklist and stops:

```
Issue quality gate FAILED for WHI-xxx:

  ✅ ## Context
  ❌ ## Acceptance Criteria  — missing or insufficient content
  ✅ ## Architecture Notes
  ❌ ## Dependencies  — missing or insufficient content
  ✅ ## Scope Boundary

Fix the issue description in Linear and re-invoke /harness-dev WHI-xxx.
```

## Required Sections

### `## Context`

What this issue is about, why it matters, and how it fits into the project. Should answer:
- What problem does this solve?
- Why now / why this priority?
- What part of the system does it touch?

### `## Acceptance Criteria`

Specific, testable criteria. Use a checklist format:

```markdown
- [ ] Concrete, observable outcome
- [ ] Another testable condition
```

Each criterion must be independently verifiable. Avoid vague phrasing like "works correctly".
Prefer "returns HTTP 200 with `{status: ok}` for valid input".

### `## Architecture Notes`

Technical decisions, patterns to follow, and files to modify. Should include:
- Key files and functions to create or modify (with paths)
- Patterns to follow (reference existing code where applicable)
- Error handling expectations
- Test requirements
- Edge cases to handle

This section is the LLM's primary technical guide. The more specific, the better.

### `## Dependencies`

What must be done before this issue can start:
- Other Linear issues (by ID) that must be in `Done` state
- External resources or services that must exist
- Write `None — no blocking dependencies.` if there are no dependencies (the sentinel must be long enough to clear the ≥20 non-whitespace-char minimum)

### `## Scope Boundary`

What is **explicitly not** in scope for this issue. This prevents scope creep and over-engineering.
Examples:
- "Do NOT add caching in this issue — that is WHI-xxx"
- "Error messages are placeholder strings only; UX copy is out of scope"
- "Only implement the happy path; edge cases are covered in WHI-xxx"

## Template

Copy this template when writing a new issue description in Linear:

```markdown
## Context
[What this issue is about, why it matters, how it fits into the project]

## Acceptance Criteria
- [ ] [Specific, testable criterion]
- [ ] [Specific, testable criterion]

## Architecture Notes
[Key technical decisions, patterns to follow, files to modify]
[Reference to CLAUDE.md architecture section if applicable]
[Specific file paths and function signatures where known]
[Error handling expectations]
[Test requirements]

## Dependencies
[Which issues must be done first, what external resources are needed]
[Or: None]

## Scope Boundary
[What is explicitly NOT in scope for this issue]
```

## Design Rationale

This schema is derived from the approved design doc at
`references/whisker-unknown-design-20260415-082854.md` (in the my-harness repo) and from
analysis of well-structured vs. poorly-structured forkcast-cli issues.

The five sections represent the minimum contract needed for an LLM to implement an issue
autonomously:
- **Context** = why (motivation and system fit)
- **Acceptance Criteria** = what (the definition of done)
- **Architecture Notes** = how (the technical plan)
- **Dependencies** = prerequisites (unblocked execution)
- **Scope Boundary** = constraints (prevents over-engineering)

An issue that satisfies all five sections can be implemented by `/harness-dev` with only
the issue description and CLAUDE.md as context — no clarifying questions to the user.
