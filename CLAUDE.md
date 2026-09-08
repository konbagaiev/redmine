# TaxDome technical challenge: Strengthen Redmine API Authentication

## What we are doing

This workspace is a job-application test task. We are implementing a focused slice of
Redmine feature ticket #43881 ("Strengthen API authentication") on top of Redmine
tag `6.1.2`, using an AI-first workflow whose artifacts are part of the deliverable.

Read `ai-workflow/context/task.md` before doing anything. It holds the candidate brief
and the ticket summary, and it is the single source of truth for the goal.

The short version:

- **Required core:** working personal access tokens (PATs). Named, multiple per user,
  expiring, hashed at rest, self-service in "My account", backward compatible with the
  legacy API key.
- **Optional, only if scoped around the core:** scopes, granular endpoint control,
  audit logging, CORS.
- **Explicitly out of scope:** rate limiting. Do not implement it.
- **Graded on:** reasoning and defensibility over line count. A small finished slice with
  strong artifacts beats a large half-finished one.

## Deliverables (from the brief)

1. A fork of `github.com/redmine/redmine`, branch off tag `6.1.2`, with an open MR/PR
   into the base branch. Reviewers must be able to clone, install, migrate, and verify.
2. AI workflow artifacts: **unedited** conversation logs, commit history, and a note on
   which tools were used and how. Never clean up, summarize, or rewrite logs.
3. A brief README: approach, what's done, what's deferred, assumptions, how to run and
   verify, how the PAT core works and its limits.

## The AI development pipeline

Work flows through four agent roles. Each role has a definition in `ai-workflow/roles/`.
**Every role runs in its own Claude Code session, started by the human.** When the
human says "act as planner" / "act as critic" / "act as implementer" / "act as
reviewer" (or the work is clearly that role's), load the matching file in
`ai-workflow/roles/` and follow it for the rest of the session. **No role ever
launches another role**: the planner does not spawn the critic, the implementer does
not spawn the reviewer, and so on. A role ends its session with a hand-over summary;
the human reads it, decides, and starts the next session. The `.claude/agents/`
definitions exist only so the human can invoke a role explicitly (for example with
`@critic`); they are not for roles to call. The human (Konstantin) co-plans and does
the final code review.

## About the human

Konstantin is an experienced engineer but has **no Ruby and no Rails experience**.
Consequences for every role:

- Explain Ruby and Rails concepts the first time they matter (routing, controllers,
  ERB views, ActiveRecord, migrations, minitest, fixtures, Bundler), briefly and tied
  to the concrete Redmine file at hand. Do not assume idioms are known.
- When proposing a design, say which Rails/Redmine mechanism it relies on and why
  that is the conventional choice, so the human can defend it in the README.
- Point to files with paths and line numbers so the human can read along.
- Never hide a Ruby-specific trade-off behind jargon. If a choice would look odd to a
  Ruby reviewer, say so plainly.

| Step | Role | Reads | Writes |
|------|------|-------|--------|
| 1 | **Planner** (`roles/planner.md`) | task context, architecture, decisions | the feature spec in `ai-workflow/specs/`, appends to `decisions.md` |
| 2 | **Critic** (`roles/critic.md`) | spec, architecture, decisions, Redmine code | a critique (returned to the human; resolutions go to the spec and `decisions.md`) |
| 3 | **Implementer** (`roles/implementer.md`) | spec, architecture, decisions | code, tests, docs (README), updates `architecture.md` |
| 4 | **Reviewer** (`roles/reviewer.md`) | spec, diff, tests | a review report (returned to the human) |
| 5 | **Human final review** | everything | merge decision |

Rules of the pipeline:

- Roles do not launch other roles. The human starts each role in a separate session
  and carries the hand-over between them. If a role thinks the next role should run,
  it says so in its closing summary and stops.
- **Only the planner writes the spec and `decisions.md`.** The critic, implementer and
  reviewer never edit either file, and neither does any session that is not running
  the planner role, including a session where the human merely approves something.
  Anything that should change a spec or become a decision (an accepted finding, an
  approval, an amendment, a reversal) is brought to a planner session, and the planner
  records it. Other roles may *propose* a decision entry in their report.
- The planner works **with** the human, not for them. It asks questions and proposes
  options; the human decides. Each decision is appended to `decisions.md` by the
  planner.
- The critic never edits the plan. It produces findings. The human and planner decide
  which findings to accept, and the planner records that in `decisions.md`.
- The implementer builds **only** what the spec says. Anything the spec does not cover
  is a question back to the human, not an improvisation.
- The reviewer checks the implementation against the spec and against Redmine's
  conventions. It does not fix code. It reports.
- Iterate steps 1-2 until the human is satisfied with the plan, then 3-4 until the
  reviewer has no blocking findings, then the human does the final review.
- **Iteration limit.** Two rounds of any loop (planner/critic or implementer/reviewer)
  are expected. If a third round is needed, stop and involve the human: report how
  many rounds have happened, which findings keep coming back, and why they were not
  resolved. The human decides how to break the loop. Never run a third round silently.

## Shared documents

All live under `ai-workflow/`. Every agent reads the ones relevant to its role before
starting, and updates only the ones its role owns.

- **`specs/<DD_MM_HH_MM>_<slug>_spec.md`** — one feature specification per feature,
  e.g. `specs/07_09_22_31_PAT_tokens_spec.md` (the PAT core). The prefix is the
  creation time (day_month_hour_minute), the slug names the feature; the file is never
  renamed afterwards. The human names the spec when starting a role session ("act as
  critic on specs/07_09_22_31_PAT_tokens_spec.md"); if not named, the newest file in
  `specs/` is the current one. Owned and **written by the planner only**; every
  other role reads it. Describes what we
  build, scope boundaries, data model, API surface, UI, tests, and acceptance criteria.
  This is the implementer's contract.
- **`decisions.md`** — **append-only** decision log, **written by the planner only**.
  Never edit or delete an entry. Each entry has an ID (`D-NNN`), date, context,
  decision, alternatives considered, and who decided. If a decision is reversed, append
  a new entry that supersedes the old one.
- **`architecture.md`** — living description of what we found in Redmine that matters
  for this task, and what we built, how, and why. Owned by the implementer for the
  "built" part and by whoever does the investigation for the "findings" part.
- **`conventions.md`** — Redmine's code and test conventions as read from the 6.1.2
  tree, with file pointers. Reference material, updated only when a convention turns
  out to be wrong or missing. The implementer follows it; the reviewer enforces it.

## Conventions

- Target codebase: Redmine 6.1.2, Ruby on Rails. **Follow Redmine's own conventions,
  not generic Rails style.** They are collected with file pointers in
  `ai-workflow/conventions.md`; the implementer and reviewer must read it. The
  non-negotiables: GPL header and `frozen_string_literal` on every Ruby file; rocket
  hash syntax in app code; `safe_attributes` for mass assignment; all strings via
  `l(:key)` added only to `config/locales/en.yml`; explicit routes in
  `config/routes.rb`; reversible migrations that work on PostgreSQL, MySQL and SQLite;
  minitest with `def test_...` names, fixtures, `Redmine::ControllerTest` /
  `Redmine::ApiTest::Base`; RuboCop clean (`bundle exec rubocop` on changed files);
  tests for every success and failure path.
- Keep the diff small and readable. The MR is the deliverable; every file in it should
  be there for a reason we can defend.
- Do not touch rate limiting. Do not refactor unrelated code.
- Commits: small, meaningful messages, made by the human or with the human's go-ahead.
  Commit history is a graded artifact.
- Logs: Claude Code stores raw session transcripts under
  `~/.claude/projects/-Users-kbagaiev-Projects-TaxDome/`. Before final submission, copy
  them unedited into `ai-workflow/logs/`. Every role session (planner, critic,
  implementer, reviewer) is a separate transcript and must be included.

## Repository and environment

- Workspace root is the fork `github.com/konbagaiev/redmine` (upstream remote:
  `redmine/redmine`). Base branch `base/6.1.2` sits on tag 6.1.2 and is the MR target.
  Work happens on `feature/personal-access-tokens`.
- Redmine runs locally in Docker: `compose.yaml` at the root, image and config under
  `docker/`. PostgreSQL 16, Ruby 3.3, development environment. The source tree is
  bind-mounted, so edits on the host are live in the container. Usage is documented
  at the top of `compose.yaml`. Run tests inside the container:
  `docker compose exec app bin/rails test <path>`.

## Current status

See `ai-workflow/architecture.md` (findings and state of the build) and the tail of
`ai-workflow/decisions.md` (latest decisions).
