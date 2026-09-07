# Decision log

**Append-only.** Never edit or delete an entry. To reverse a decision, append a new entry
that says "Supersedes D-NNN". Entries are numbered sequentially.

Format:

```
## D-NNN: <short title>
- Date: YYYY-MM-DD
- Decided by: <human | human + planner | ...>
- Context: <what question came up and why>
- Decision: <what we chose>
- Alternatives considered: <what we did not choose and why>
- Consequences: <what this commits us to>
- References: <critique finding C-n, review finding R-n, ticket note, file, ...>
```

---

## D-001: Use a four-role AI pipeline with shared documents
- Date: 2026-09-07
- Decided by: human
- Context: The challenge is graded on AI-workflow artifacts as much as on code. We need
  a repeatable structure that shows how the human and the LLM divided the work.
- Decision: Four roles (planner, critic, implementer, reviewer), each defined in
  `ai-workflow/roles/` and exposed as a Claude Code subagent in `.claude/agents/`.
  Three shared documents: `spec.md` (planner-owned contract), `decisions.md` (this
  file, append-only), `architecture.md` (findings + what was built). The human
  co-plans with the planner and does the final code review after the reviewer.
- Alternatives considered: single-agent chat (less traceable); more roles such as a
  separate tester or security auditor (overhead for a ~2 hour slice; the critic and
  reviewer cover security explicitly instead).
- Consequences: Every design choice must land here before the implementer acts on it.
  Roles do not write documents they do not own.
- References: `CLAUDE.md`, `ai-workflow/roles/*.md`

## D-002: Rate limiting is out of scope
- Date: 2026-09-07
- Decided by: human (mandated by the brief)
- Context: The brief forbids implementing the rate-limiting pillar; it is already being
  handled upstream in #43881 (Iurii Dremov's patch, steered by Marius Bălteanu toward
  Rails' `rate_limit`).
- Decision: No rate limiting of any kind, including "lightweight" or "just a header".
- Alternatives considered: none.
- Consequences: Agents must flag and refuse anything that resembles rate limiting.
- References: candidate brief; `ai-workflow/context/task.md`

## D-003: Repository layout and local environment
- Date: 2026-09-07
- Decided by: human
- Context: The brief requires a fork of `github.com/redmine/redmine` branched off tag
  `6.1.2` and an open MR. Reviewers must be able to clone, install, migrate, and verify.
- Decision: Fork `redmine/redmine` into the human's GitHub account (`konbagaiev`).
  The workspace root `/Users/kbagaiev/Projects/TaxDome` becomes the fork checkout, so
  `CLAUDE.md` and `ai-workflow/` are committed on the feature branch and ship with the
  MR as the AI-workflow artifacts. Redmine runs locally in Docker (app + database via
  `docker compose`) so setup is reproducible for reviewers.
- Alternatives considered: Redmine in a `redmine/` subfolder with workflow files
  outside the MR (loses the artifacts from the deliverable); native Ruby install
  (less reproducible for reviewers).
- Consequences: The MR diff will include non-Redmine files (`CLAUDE.md`,
  `ai-workflow/`, Docker files). The README must explain them. Docker files must not
  interfere with Redmine's own configuration conventions.
- References: candidate brief, deliverable 1 and 2

## D-004: First slice is PATs end to end; other pillars decided afterwards
- Date: 2026-09-07
- Decided by: human
- Context: The brief requires working PATs; other pillars are optional. Choosing
  optional pillars before the core exists would be guessing about remaining time and
  about how the PAT design shapes them.
- Decision: Step one is personal access tokens complete in code and UI, with hashed
  storage. Only after PATs are implemented, tested, and reviewed do we decide which
  optional pillar (if any) to add. Rate limiting stays out (see D-002).
- Alternatives considered: planning scopes or audit logging into the first slice
  (rejected: risk of a half-finished larger slice, which the rubric penalizes).
- Consequences: The spec covers PATs only for now. The planner must design the PAT
  model so that scopes could be added later without a rewrite, but must not build them.
- References: candidate brief ("small slice with strong artifacts beats a half-finished
  large one"); `ai-workflow/context/task.md`
