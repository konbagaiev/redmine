# Personal access tokens for the Redmine REST API

This is the TaxDome technical challenge: a slice of Redmine issue
[#43881](https://www.redmine.org/issues/43881) ("Strengthen API authentication") built on tag `6.1.2`.
Branch `feature/personal-access-tokens`, merge request into `base/6.1.2` inside this fork:
https://github.com/konbagaiev/redmine/pull/1. Redmine's own `README.rdoc` is unchanged. Things found
along the way that a maintainer should know about are in [FINDINGS.md](FINDINGS.md).

## Approach

1. Set up my AI workflow, adjusted to this task: two agent pairs, planner ↔ critic and
   implementer ↔ reviewer, and four shared documents (architecture, decisions, specs, conventions). All
   of it lives in `ai-workflow/`; the rules for every session are in `CLAUDE.md`.
2. Deploy Redmine locally and investigate the current state: how API keys work today, how they are
   created, reset and used, both in the UI and in the code.
3. Investigate what Redmine already has, and find the OAuth tokens for applications built on
   Doorkeeper.
4. Using all of this, plan the PAT implementation with the planner. Decisions made along the way:
   a separate page under My account to create and revoke tokens, the expiry values, the token format,
   and so on. Only PAT support is in scope for now; the other items from the ticket can be done later,
   and the design keeps them in mind.
5. The investigation and planning session produced a seven-step plan. Since this is the first feature
   in this project, I run every agent in its own session so that I can evaluate its work; the long-term
   goal is to polish the roles over the first ten features and then turn them into subagents.
6. The plan was reviewed by the critic in a separate session. The critic had findings in two rounds
   (C-1 to C-15, recorded in D-020 and D-023) and approved on a third pass; once the critic and I
   approved the plan, implementation started.
7. For each step of the plan: the implementer builds it, the reviewer checks it, then I do my own code
   review, and after my approval the implementer commits and we move to the next step.
8. The last step is this document. I wrote it by hand and asked the agent to check spelling and every
   factual claim against the code.

The central decision was to follow what core maintainer Holger Just asked for in the ticket and reuse
what is already built for OAuth applications: **a PAT is a Doorkeeper access token without an
application**, issued from My account. Doorkeeper already provides hashed storage, per-token expiry,
revocation, lookup and the scope hook, all reviewed by the maintainers; this branch adds what it lacks
for self-service: a name, last-used tracking, a recognisable format, issuance from My account, and
acceptance on the legacy transports. The alternative, a standalone table, was rejected after the
planner read the gem source and probed it in the container (`ai-workflow/architecture.md` 1.3.1,
D-010).

## What is done

The core requirement: personal access tokens with per-token expiry, hashed storage, and the secrets
filtered out of the logs. In detail:

- Named tokens, several per user, each with a mandatory expiry from a list (7–365 days, default 30).
- SHA-256 at rest through Doorkeeper's `hash_token_secrets`; plaintext shown exactly once.
- Works on every transport the legacy key works on: `Authorization: Bearer`, `X-Redmine-API-Key`,
  `?key=`, HTTP Basic username. Expired, revoked, unknown, and locked-user tokens are refused.
- Self-service page under My account: list, create, revoke; create and revoke behind sudo mode.
- `last_used_at`, written at most once a minute.
- Admin setting `personal_access_token_max_lifetime` on the API tab (default 0 = no cap), enforced
  server-side.
- `key` and `bearer_token` filtered from the request log.
- The legacy API key is untouched and keeps working.
- Two fixes from Redmine 6.1.4 (#44343, #44371) backported because the slice needs them, and one fix
  of our own; see FINDINGS.md.

## What is deferred, and why

I came to this task without Ruby, Rails or Redmine experience, and I chose to spend the time on
understanding the codebase and getting the core design right rather than on covering more pillars:
reading how authentication, Doorkeeper, `Token`, sudo mode and the test conventions actually work,
and deciding with evidence rather than by description. The brief's own rule, a small finished slice
over a large half-finished one, pointed the same way.

Two things make the deferred items cheaper than they look. Scopes are currently blocked by #44271,
but because a PAT is a Doorkeeper token they are already stored on the row and already enforced
through `User#oauth_scope`; adding them is a form field and one line in `find_current_user`, once
#44271 is fixed. And the agent pipeline built for this task (spec, critic, implementer, reviewer,
decision log) is reusable as is: each remaining pillar is one more spec through the same loop.

| Item | Reason |
|---|---|
| Scoped permissions (pillar 2) | The mechanism exists and the hook is one line, but open defect #44271 makes scopes ineffective on issue edit, notes and delete. A "read-only" token that can write is worse than none. Prerequisite: fix #44271. |
| Audit logging (pillar 4) | Separate concern; the maintainer asked for separate patches. `last_used_at` is the only trace added. |
| Admin token overview panel | UI without new logic; separate patch. |
| Legacy key deprecation or migration | The ticket asks for a transition period; migrating is irreversible and breaks the "show key" screen. |
| Per-role permission to create tokens (asked in the thread) | Redmine permissions are project-scoped; needs its own design. |
| Rate limiting (pillar 3) | Excluded by the brief. |
| Endpoint control, CORS (pillars 5, 6) | Unrelated to tokens. |

## Assumptions

- No maintainer-approved design exists (#43881 is New). Decisions follow the 6.1.2 conventions and
  Holger Just's comment; each is in `ai-workflow/decisions.md` (D-001–D-030).
- Verified on PostgreSQL 16 in Docker. MySQL and SQLite portability rests on plain ActiveRecord.
- `test/system` (Chrome) was not run; the Docker image has no browser.
- The patches attached to the ticket were not downloaded or applied; the thread's text was used as
  requirements input only, so the design here is our own.

## How the PAT core works

- **Data.** Three nullable columns on `oauth_access_tokens` (`name`, `last_used_at`, `token_suffix`).
  `PersonalAccessToken < Doorkeeper::AccessToken` shares the table; its `personal` scope and the
  `User#personal_access_tokens` association narrow it to `application_id IS NULL`.
- **Format.** `rmpat_` + Doorkeeper's 43-character random part; the underscore alone fails the legacy
  key's `/\A[a-z0-9]+\z/i` lookup, so the two mechanisms cannot collide. The last four characters
  are stored for display.
- **Expiry.** The lifetime becomes Doorkeeper's per-token `expires_in`. The admin cap trims the list
  and a model validation rejects anything above it. No refresh token is ever issued.
- **Authentication** (`ApplicationController#find_current_user`): legacy key first, then Doorkeeper,
  then Basic. The legacy transports are registered as Doorkeeper `access_token_methods`. A token
  without an application, without scopes and with an expiry grants the owner's full rights, like the
  legacy key; `oauth_scope` is not set for it. Every other token behaves as in 6.1.2.
- **Show once.** `create` redirects to the list with the plaintext in the flash, Array-wrapped and
  consumed by the controller's first `before_action`, so Redmine's layout (which prints every String
  flash value) never renders it. The list shows it once with `Cache-Control: no-store`.
- **Revoke** sets `revoked_at` and keeps the row, as Doorkeeper does.

## Limits of the approach

- A PAT bypasses 2FA and password expiry exactly as the legacy key does. On the Basic transport a
  legacy key is checked for `must_change_password?` and a PAT is not.
- An expired or revoked token answers with Doorkeeper's `Bearer … invalid_token` challenge, an unknown
  one with Redmine's `Basic realm`; a caller can tell "dead" from "never existed".
- A wrong legacy key no longer short-circuits to 401; the request falls through to Doorkeeper and
  Basic. Needed so a PAT in the legacy header reaches Doorkeeper.
- `access_token_methods` is global: OAuth application tokens are now also accepted via
  `X-Redmine-API-Key`, `?key=` and the Basic username, and `/oauth/token/info` accepts a PAT.
  `/oauth/revoke` is unchanged.
- A token inserted into `oauth_access_tokens` outside the UI without an expiry is not a PAT: it
  authenticates with an empty scope and can do nothing, as in 6.1.2 (D-030).
- The plaintext transits the encrypted session cookie once. In development and test the Rails error
  page dumps the session, so an exception right after creation can show it there.
- We depend on Doorkeeper model details beyond what Redmine used so far (`plaintext_token`, the
  generator hook, optional application). The gem is pinned `~> 5.8.2`; unit tests pin the contract.
- Name uniqueness per user is a model validation only. Revoked rows accumulate: Doorkeeper ships
  `doorkeeper:db:cleanup` rake tasks, but Redmine never calls `Doorkeeper::Rake.load_tasks`, so they
  are not available and the rows stay until deleted by hand. Reverse proxies may still log `?key=`.

## How to run and verify

```bash
git clone https://github.com/konbagaiev/redmine.git redmine-pat
cd redmine-pat
git checkout feature/personal-access-tokens
```

Docker is a convenience, not a requirement: nothing in the code is container-specific, and a standard
Redmine install (Ruby 3.2+, `bundle install`, your own `config/database.yml`, `bin/rails db:migrate`)
works the same way. With Docker:

```bash
docker compose up -d --build          # Ruby 3.3, PostgreSQL 16; app on :3300, db on :5433
docker compose exec app bin/rails db:create db:migrate
docker compose exec app bin/rails redmine:load_default_data REDMINE_LANG=en
open http://localhost:3300             # admin / admin, you are asked to change it
```

1. Administration → Settings → API: enable the REST web service; optionally set the maximum lifetime.
2. My account → Personal access tokens → create one. Copy the `rmpat_…` value: it is shown once.
3. With `T=<token>` and `H=http://localhost:3300`:

```bash
curl -i -H "Authorization: Bearer $T"  $H/users/current.json   # 200
curl -i -H "X-Redmine-API-Key: $T"     $H/users/current.json   # 200
curl -i "$H/users/current.json?key=$T"                         # 200; log shows "key"=>"[FILTERED]"
curl -i -u "$T:x"                      $H/users/current.json   # 200
```

4. Revoke it on the page: the same requests answer 401. The legacy key keeps working throughout.

Tests, lint and eager-load check (all green at submission: 287 runs, 1097 assertions):

```bash
docker compose exec app bin/rails test \
  test/unit/personal_access_token_test.rb test/unit/user_test.rb test/unit/lib/parameter_filtering_test.rb \
  test/integration/api_test/personal_access_token_authentication_test.rb \
  test/functional/personal_access_tokens_controller_test.rb test/functional/settings_controller_test.rb \
  test/functional/my_controller_test.rb test/integration/sudo_mode_test.rb test/integration/routing/my_test.rb
docker compose exec app bundle exec rubocop app/models/personal_access_token.rb \
  app/controllers/personal_access_tokens_controller.rb app/controllers/application_controller.rb \
  app/models/user.rb config/initializers/30-redmine.rb config/application.rb
docker compose exec app bin/rails zeitwerk:check
```

## AI workflow artifacts

Tool: Claude Code, no other AI tools. Role definitions in `ai-workflow/roles/`, the spec in
`ai-workflow/specs/`, the append-only decision log in `ai-workflow/decisions.md`, findings and what was
built in `ai-workflow/architecture.md`, Redmine conventions with file pointers in
`ai-workflow/conventions.md`. The unedited session transcripts, one per role session, are copied into
`ai-workflow/logs/` by `ai-workflow/logs/export.sh` before submission; see `ai-workflow/logs/README.md`
for the layout, which session played which role, and how to read them.
