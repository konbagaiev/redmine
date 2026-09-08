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

## D-005: PAT UI is a dedicated page under My account; legacy key block untouched
- Date: 2026-09-07
- Decided by: human + planner
- Context: Where the self-service PAT UI lives. The My account sidebar
  (`app/views/my/_sidebar.html.erb:21-46`) is a narrow column that already holds the
  legacy "API access key" block; a token list with name, expiry, last use and revoke
  plus a create form does not fit there.
- Decision: A dedicated page at `my/api_tokens` served by a new controller (same shape
  as `TwofaController` / `TwofaBackupCodesController`, which serve `my/twofa/*`),
  with list, inline create form and per-row revoke, following the "additional emails"
  page (`app/views/email_addresses/_index.html.erb`, `EmailAddressesController`).
  The page renders the `my/sidebar` partial like the OAuth authorized-applications
  page does, so the legacy API key block (show/copy/reset) appears there unchanged.
  `_sidebar.html.erb` is not modified; no PAT link in the sidebar. The only entry
  point is a link in the contextual bar of My account
  (`app/views/my/account.html.erb:4`), next to "Authorized applications".
  The legacy API key keeps working and stays visible in both places.
- Alternatives considered: inline in the sidebar (no room, bloats `account.html.erb`);
  actions added to `MyController` (already a grab bag; separate controller is the
  precedent for `/my/*` features); admin tab on the user edit page (deferred, see
  D-004; first candidate add-on after the core); removing the legacy key block
  (breaks the backward-compatibility expectation shared by everyone in #43881).
- Consequences: new controller, views and hand-written routes under `my/api_tokens`;
  `require_sudo_mode` on create and revoke as `EmailAddressesController` does; the
  README documents that the legacy key is unchanged.
- References: `ai-workflow/architecture.md` 1.4; D-004

## D-006: Expiry is mandatory and chosen from a lifetime picker
- Date: 2026-09-07
- Decided by: human
- Context: #43881 pillar 1 requires mandatory expiration. The form needs an input for
  it that is simple to validate and to defend.
- Decision: The create form offers a lifetime select (7, 30, 60, 90, 180, 365 days,
  the same list and "N days" labels `password_max_age` uses in
  `app/views/settings/_authentication.html.erb:26`). There is no "never" option.
  The server computes and stores `expires_at` (datetime, not null). Submitted values
  are validated against the allowed list; nothing is trusted from the client.
- Alternatives considered: a date picker (`f.date_field` + `calendar_for`, as issue
  due dates): more flexible, but needs a rule for which instant "valid to <date>"
  means and time-zone handling; more code for no gain in the core.
- Consequences: `expires_at` is compared to the current time at authentication;
  the list shows the exact expiry with `format_time`. An admin cap (D-008) is a cap
  on this list.
- References: D-008

## D-007: Plaintext is shown once via the backup-codes flow (redirect, flash, no_store)
- Date: 2026-09-07
- Decided by: human + planner
- Context: The plaintext token must be displayed exactly once. Rendering it directly
  in the POST response fails on browser refresh (form resubmission prompt, duplicate
  or confusing error). Redmine already solves one-time display for 2FA backup codes
  in `app/controllers/twofa_backup_codes_controller.rb:43-70`.
- Decision: `create` saves the token, puts the plaintext in the flash, and redirects
  to the token list (redirect-after-POST, so refresh is a plain GET). The list action
  reads and deletes the flash key; when present it renders a highlighted box with the
  plaintext and the existing copy button and sends `no_store`; when absent (refresh
  or any later visit) it renders the plain list with a notice that the token cannot
  be shown again. Difference from the backup-codes precedent: backup codes are stored
  in plaintext and re-read from the DB, a PAT is stored hashed, so the plaintext
  itself travels one hop in the flash (encrypted cookie session,
  `config/application.rb:103-108`), then is gone.
- Alternatives considered: render on POST (fails refresh); server-side temporary
  store for the plaintext (over-engineered); a separate "created" page (same flash
  mechanism, one more view for nothing).
- Consequences: the plaintext transits the session cookie exactly once; the README
  notes this and the `no_store` header. Functional tests must cover: shown after
  create, absent after refresh.
- References: `TwofaBackupCodesController#create/#show`; `en.yml`
  `twofa_backup_codes_already_shown` as the wording precedent

## D-008: Admin maximum lifetime setting, default 0 = no cap
- Date: 2026-09-07
- Decided by: human
- Context: #43881 phase one lists an admin max-lifetime policy. Options were: no
  setting (fixed picker), one setting, or a fuller policy set (per-role creation
  permission, legacy key switch).
- Decision: One setting `personal_access_token_max_lifetime`, integer days, declared
  in `config/settings.yml` with `format: int`, `default: 0`, `security_notifications: 1`
  (mirrors `password_max_age`, l.54-57). Rendered with `setting_select` on the admin
  API tab (`app/views/settings/_api.html.erb`) with "disabled" + the same day list.
  0 means no cap (Redmine idiom, upgrade-neutral). The lifetime picker only offers
  values within the cap, and the model validates `expires_at` against the cap so a
  crafted request cannot bypass it. The cap applies at creation only; lowering it
  later does not shorten existing tokens.
- Alternatives considered: no setting (ceiling hard-coded); conservative default
  such as 365 (changes behaviour on upgrade, unlike other new settings); fuller
  policy set (doubles UI and test surface; deferred as add-ons).
- Consequences: settings.yml, one `setting_*` i18n key, one line on the API tab,
  one model validation, one unit and one functional test.
- References: D-006; `app/models/user.rb:356-364` for the 0-means-off idiom

## D-009: Store the last four characters of the token for identification
- Date: 2026-09-07
- Decided by: human
- Context: With hashed storage the list cannot show any part of the token, so a
  user with several tokens cannot tell which row a script is using. The planner
  proposed deferring this; the human judged the cost negligible and the value real.
- Decision: The model keeps a short suffix column (last 4 characters of the
  plaintext) set at creation and shown in the list next to the name, e.g.
  "…ab12". It is display-only: lookup goes through the hash, never through the
  suffix.
- Alternatives considered: defer (saves one column, loses usability); showing a
  prefix instead (a fixed prefix identifies the token type, not the token).
- Consequences: one extra column in the migration and the fixture; the README
  states that 4 characters of a high-entropy secret do not weaken it.
- References: D-007

## D-010: PATs are application-less Doorkeeper access tokens, not a new token model
- Date: 2026-09-07
- Decided by: human + planner
- Context: The central design fork in #43881. Core maintainer Holger Just prefers
  extending the existing OAuth machinery over a standalone PAT model; Bogdan Egikov
  listed why OAuth-only does not serve the PAT use case today (no self-issue, no
  name/last-used, global expiry, Bearer-only transport). The planner read the
  Doorkeeper 5.8.2 source and probed the container (findings in
  `architecture.md` 1.3.1): an access token with `application_id: nil` is valid,
  SHA-256 hashed, looked up by plaintext, expires per row, revokes, and already
  authenticates via `Authorization: Bearer` with no code change.
- Decision: A personal access token is a `Doorkeeper::AccessToken` row with no
  application, issued by the user from My account. Implemented as a Redmine model
  `PersonalAccessToken < Doorkeeper::AccessToken` (same table, no STI, scoped to
  `application_id IS NULL`) carrying our validations, plus a migration adding
  `name`, `last_used_at` and the display suffix (D-009) to `oauth_access_tokens`.
  Legacy transports (`X-Redmine-API-Key`, `?key=`, Basic username) are wired through
  Doorkeeper's `access_token_methods` (lambdas + `from_basic_authorization`), and
  `find_current_user` is reordered so Doorkeeper is consulted when the legacy key
  lookup returns nil. A PAT with blank scopes is full access: `find_current_user`
  skips `oauth_scope=` for application-less tokens with no scopes, so `admin?` is
  not silently dropped (Bogdan Egikov's "blank = full access"). Scopes remain a
  later, UI-only pillar (D-004). The user-deletion foreign-key gap on
  `oauth_access_tokens` is fixed by deleting the user's tokens in
  `User#remove_references_before_destroy`.
- Alternatives considered: standalone `personal_access_tokens` table and model
  (duplicates hashing, expiry, revocation and scope plumbing that Doorkeeper already
  provides, which is exactly the maintainer's objection); a built-in per-user OAuth
  application (pollutes "Authorized applications", revoking the app kills all PATs);
  a synthetic shared "Personal tokens" application (same problem, plus a seed row).
- Consequences: We depend on Doorkeeper model features beyond what Redmine used so
  far: optional application, `plaintext_token`, the token generator hook and the
  secret strategy. These are documented features and the gem is pinned `~> 5.8.2`
  (`Gemfile:22`, patch-level updates only), and Redmine's OAuth provider already
  depends on the same gem. Risk is mitigated by unit tests that pin the contract:
  stored token equals SHA-256 of the plaintext, lookup by plaintext succeeds,
  expiry and revocation refuse authentication, app-less rows never appear on
  "Authorized applications". Expired PATs on legacy transports answer with
  Doorkeeper's Bearer-style 401; documented as a known difference. The README
  explains the design as "the maintainer's direction, made self-service".
- References: #43881 notes by Holger Just and Bogdan Egikov; `architecture.md`
  1.3 and 1.3.1; D-004, D-005 to D-009

## D-011: Token format is a fixed prefix plus Doorkeeper's random part
- Date: 2026-09-07
- Decided by: human
- Context: Doorkeeper generates a 43-char base64url token. A recognisable prefix makes
  tokens identifiable in logs, support requests and secret scanners.
- Decision: Plaintext = `rmpat_` + `Doorkeeper::OAuth::Helpers::UniqueToken.generate`.
  Implemented by overriding the instance method `token_generator`
  (`access_token_mixin.rb:503-509`) in `PersonalAccessToken` only; OAuth-flow tokens
  are unchanged. The hash stored at rest covers the full string, so lookup is
  unaffected. The display suffix (D-009) is the last 4 characters of the random part.
- Alternatives considered: the global `access_token_generator` option (would change
  OAuth-flow tokens too); no prefix (harder to recognise).
- Consequences: a unit test asserts the prefix and that the stored value is
  SHA-256 of the full plaintext.
- References: D-009, D-010

## D-012: PATs are accepted on every legacy transport, and secrets are filtered from logs now
- Date: 2026-09-07
- Decided by: human
- Context: Backward compatibility means a PAT must work wherever the legacy key works.
  `?key=` puts the secret in the query string, which Rails logs; upstream #44371
  filters `key` but has no release date.
- Decision: A PAT is accepted via `Authorization: Bearer`, the `access_token` /
  `bearer_token` params (Doorkeeper defaults), `X-Redmine-API-Key`, `?key=` and as the
  HTTP Basic username, through `access_token_methods` in the Doorkeeper config.
  In the same slice, `config.filter_parameters` gains anchored patterns for `key` and
  `bearer_token` (Doorkeeper already filters `access_token`, `refresh_token`,
  `client_secret`, `code`; `doorkeeper/engine.rb:5-11`). We do not wait for #44371:
  a security feature must not leak its own secret into the request log. Headers are
  not written to the Rails log, so `X-Redmine-API-Key` and `Authorization` need no
  filter.
- Alternatives considered: Bearer only (breaks every existing client); wait for
  #44371 (unknown date, leaves the feature insecure in the meantime).
- Consequences: one line in `config/application.rb`; a test that a request with
  `?key=` is logged with `[FILTERED]`. Overlap with #44371 is documented in the
  README so the maintainers can drop whichever lands second.
- References: `architecture.md` 1.8; D-010

## D-013: Last-used tracking reuses the last-login throttle pattern
- Date: 2026-09-07
- Decided by: human
- Context: #43881 and #43938 ask for last-used tracking; writing on every API call is
  wasteful.
- Decision: `last_used_at` is written with a direct column update, skipped when the
  previous value is less than one minute old, exactly like
  `User#update_last_login_on!` (`app/models/user.rb:328-331`).
- Alternatives considered: write on every request (write amplification); no
  tracking (ticket requirement).
- Consequences: the list shows "last used N ago" or "never"; tests cover the
  throttle.
- References: D-010

## D-014: Revoke, do not delete; expired tokens stay visible until revoked
- Date: 2026-09-07
- Decided by: human
- Context: Doorkeeper's model is to set `revoked_at` and keep the row.
- Decision: The UI "Revoke" action sets `revoked_at` (Doorkeeper `#revoke`). The list
  shows non-revoked tokens, expired ones flagged "expired" with the same Revoke
  action so the user can clean up. Revoked rows are kept (useful for a later audit
  pillar) and are not shown.
- Alternatives considered: hard delete (loses history, inconsistent with OAuth
  tokens); hide expired tokens (user cannot clean up).
- Consequences: the per-user name uniqueness check applies to non-revoked tokens
  only.
- References: D-010

## D-015: The user-deletion foreign-key fix is a separate first commit and a README item
- Date: 2026-09-07
- Decided by: human
- Context: Destroying a user who has any Doorkeeper token or grant fails with a
  foreign-key violation (`architecture.md` 1.3.1). Storing PATs in that table makes
  the bug reachable by every PAT user.
- Decision: First commit of the branch: `User#remove_references_before_destroy`
  deletes the user's `oauth_access_tokens` and `oauth_access_grants` rows, with a
  unit test. The README lists it under "important items to discuss" because it
  changes existing OAuth behaviour, and the MR description flags it for the
  maintainers.
- Alternatives considered: fold it into the PAT commit (hides an unrelated fix);
  `on_delete: :cascade` on the foreign keys (Redmine does not use cascading FKs).
- Consequences: reviewers can evaluate and cherry-pick the fix on its own.
- References: D-010

## D-016: No cleanup of already-issued secrets on legacy transports beyond filtering
- Date: 2026-09-07
- Decided by: human + planner
- Context: Clarifies D-012's scope. Reverse proxies and web servers may log query
  strings independently of Rails.
- Decision: The slice filters Rails' own parameter logging only. The README states
  that `?key=` is discouraged and that front-end server logs are outside Redmine's
  control; header or Basic transport is recommended for PATs.
- Alternatives considered: rejecting `?key=` for PATs (breaks compatibility parity
  with the legacy key).
- Consequences: documentation only.
- References: D-012

## D-017: Spec v1 details settled at the end of planning round 1
- Date: 2026-09-07
- Decided by: human
- Context: The planner listed five open questions after drafting `spec.md` v1.
- Decision: (1) The README deliverable is a new `README.md` at the repository root;
  Redmine's `README.rdoc` is untouched. (2) The My account link uses the `lock` sprite
  icon (`key` is taken by "Change password"). (3) The lifetime picker preselects 30
  days, the common default of GitHub, GitLab and Azure DevOps. (4) Sudo-mode
  protection of create/revoke is verified by an integration test in
  `test/integration/sudo_mode_test.rb`, following `test_update_email_address`.
  (5) When the admin cap is not one of the picker values, the picker offers only
  values at or below the cap; no extra code, since the admin UI can only set list
  values and an off-list cap needs the console or a plugin.
- Alternatives considered: a section inside the existing README (would mix Redmine's
  own docs with the challenge deliverable); 90-day default (defensible, less common);
  skipping the sudo test (leaves a security declaration unverified); adding the cap
  itself as a picker option (code for an unreachable case).
- Consequences: `spec.md` v1 has no open questions and goes to the critic.
- References: `spec.md` sections 5.3, 8.4a, 9, 11

## D-018: Every role runs in its own session started by the human; roles never launch roles
- Date: 2026-09-07
- Decided by: human
- Context: D-001 described the critic, implementer and reviewer as Claude Code
  subagents. At the end of planning round 1 the planner launched the critic as a
  subagent; the human stopped it. The human wants to start each role himself in a
  separate session so that every role's reasoning is a first-class, visible transcript
  and the hand-over between roles is a human decision.
- Decision: Partially supersedes D-001. Each of the four roles runs in a separate
  Claude Code session that the human starts ("act as critic", etc.). No role launches
  another role. A role ends with a hand-over summary; the human carries it to the next
  session. The `.claude/agents/` definitions remain only for explicit invocation by
  the human. `CLAUDE.md` and all four role files were updated accordingly.
- Alternatives considered: planner-orchestrated subagents (hides the critic's
  transcript inside the planner's session and removes the human from the hand-over).
- Consequences: The critic run started by the planner on 2026-09-07 was killed before
  producing output and is not part of the record. Logs to submit are one transcript
  per role session.
- References: D-001; `CLAUDE.md` "The AI development pipeline"; `ai-workflow/roles/*.md`

## D-019: One spec file per feature under `ai-workflow/specs/`, timestamp + slug
- Date: 2026-09-07
- Decided by: human
- Context: A single `ai-workflow/spec.md` cannot hold more than one feature; optional
  pillars added after the PAT core (D-004) need their own specs and their own
  critic/implementer/reviewer rounds.
- Decision: Specs live in `ai-workflow/specs/`, named `<DD_MM_HH_MM>_<slug>_spec.md`
  where the prefix is the creation time and the slug names the feature. The PAT core
  spec is `specs/07_09_22_31_PAT_tokens_spec.md` (moved from `spec.md`, content
  unchanged). Files are never renamed. The human names the spec when starting a role
  session; otherwise the newest file is the current one. `CLAUDE.md`, the role files
  and the agent definitions were updated.
- Alternatives considered: one growing `spec.md` with sections per feature (hard to
  review and to critique per feature); numbered `spec-1.md` (no date, no name).
- Consequences: Decision entries and reports reference specs by file name from now on.
  Earlier entries (D-005 to D-018) that say `spec.md` mean the PAT core spec.
- References: D-004, D-018

## D-020: Critic round 1 on the PAT core spec: all 11 findings accepted
- Date: 2026-09-07
- Decided by: human
- Context: The critic (own session, D-018) reviewed
  `specs/07_09_22_31_PAT_tokens_spec.md` v1 and returned C-1 to C-11: two blocking
  (C-1 lifetime validation rejects every form post because the form sends a String and
  the allowed list holds Integers; C-2 the plaintext in the flash could be printed by
  the layout on an error page) and nine non-blocking.
- Decision: Accept all eleven. Applied in spec v2: C-1 normalising `lifetime_days=`
  writer with `Integer(value, exception: false)`; C-2 see D-022; C-3 see D-021;
  C-4 document the global effect of `access_token_methods` on `/oauth/token/info` and
  self-revocation via `/oauth/revoke`, pin the latter with a test; C-5 `architecture.md`
  1.3 (e), 1.6, 1.8 and section 3 corrected, `custom_access_token_attributes` cited;
  C-6 no separate `expires_in` presence validation; C-7 `expire_sudo_mode!` in the
  sudo test; C-8 `destroy` looks up through `not_revoked` (404 for a revoked id);
  C-9 `bin/rails zeitwerk:check` replaces `test:autoload` in the acceptance list;
  C-10 flash strings are static i18n only; C-11 i18n keys verified absent, hedges
  removed.
- Alternatives considered: rejecting C-4's test as scope creep (kept: it pins existing
  gem behaviour we now expose, five lines); rejecting C-9 (kept: the only
  eager-load-sensitive piece in the design deserves the check).
- Consequences: spec v2 is the implementer's contract if the human approves it without
  a second critic round.
- References: critic report round 1 (separate session transcript); spec v2

## D-021: PATs equal the legacy API key with respect to 2FA and password expiry
- Date: 2026-09-07
- Decided by: human (critic finding C-3)
- Context: #43881's first listed core issue is that API access bypasses 2FA. The spec
  inherits the bypass but v1 did not record it as a decision, and stated the
  password-expiry behaviour imprecisely.
- Decision: A PAT is not subject to 2FA and does not check `must_change_password?`,
  exactly like the legacy key on header and `?key=` transport. Nuance: a legacy key
  sent as the HTTP Basic username is checked for `must_change_password?` by the Basic
  branch (`application_controller.rb:154-157`); a PAT sent the same way is consumed by
  Doorkeeper first and is not. A stronger policy (for example refusing PATs for users
  who must activate 2FA, or a "require 2FA to create tokens" rule) is a follow-up.
- Alternatives considered: enforce `must_change_password?` on the PAT path (diverges
  from the legacy header path for no clear gain in this slice); block PAT creation
  when 2FA is mandatory but not active (policy work, deferred).
- Consequences: stated in spec 4.2 and in the README limits section.
- References: C-3; `architecture.md` 1.10

## D-022: The plaintext flash value is consumed by the first before_action and Array-wrapped
- Date: 2026-09-07
- Decided by: human (critic finding C-2). Amends D-007.
- Context: Redmine's layout renders every String flash value on every page
  (`render_flash_messages`, `application_helper.rb:516-524`). With D-007 as written,
  a 403 (REST API disabled, sudo mode) or a 500 between the redirect and `index`
  would print the token in a generic flash box on a page without `no_store`.
- Decision: `PersonalAccessTokensController` declares
  `before_action :read_new_token_from_flash` before every other callback; it moves the
  value into an instance variable and deletes the flash key on every action.
  Additionally `create` stores the plaintext wrapped in an Array, which the layout's
  `is_a?(String)` guard skips by construction (as the backup codes store an Array of
  ids). Two negative tests assert no `#flash_personal_access_token` element on the
  successful index and on a 403 with the flash set. Known UX limit documented: a
  session expiring between POST and GET loses the token; the user recreates it.
- Alternatives considered: keep the plaintext out of the flash entirely via a
  server-side one-time store (over-engineered, D-007); rely on `index` deleting the
  key (the gap the critic found).
- Consequences: spec 5.2 and 8.4 updated; README limits mention the UX case.
- References: C-2; D-007

## D-023: Critic round 2 on the PAT core spec: C-12 to C-15 accepted; corrects D-020 and D-022
- Date: 2026-09-07
- Decided by: human
- Context: The critic's second round (own session) reviewed spec v2 and found one
  blocking error in its own round-1 finding C-4 plus three non-blocking items.
- Decision: Accept all four. **Correction to D-020's C-4 sentence:** `POST /oauth/revoke`
  is not affected by this slice and does not revoke a PAT without client credentials.
  It reads `params["token"]` directly and `validate_presence_of_client`
  (`doorkeeper/tokens_controller.rb:5, 64-78`) answers 403 unless the caller
  authenticates as a registered `Doorkeeper::Application`; with such credentials an
  application-less token is revoked (`authorized?`, l.102-112). The pinning test and
  the README "self-revocation" line are removed (C-12). `architecture.md` 1.3.1 and
  1.4 now record the `/oauth/token/info` transport effect, the `/oauth/revoke`
  behaviour, `render_flash_messages` being the sole flash iterator and skipping
  non-Strings, and the development-only error-page session dump (C-13). The session
  dump is documented as a development/test-only limit in spec 5.2 and the README
  (C-14). Wording fixes (C-15): `attr_reader` plus writer in 3.2; "read, then delete"
  in 5.2; the acceptance list keeps `test:autoload` (CI runs it) **and** adds
  `zeitwerk:check`, so D-020's "replaces" reads "adds". **Correction to D-022:** the
  sentence "a 403 (REST API disabled, sudo mode)" is imprecise; sudo mode never guards
  `index` and renders 200 when it intercepts `create`/`destroy`. The 403 cases are
  REST API disabled and any other `deny_access`; the sudo-mode interception page is a
  200 that the first `before_action` has already protected.
- Alternatives considered: keeping the revoke test against a registered application
  (tests gem behaviour outside our diff; dropped).
- Consequences: spec v3. Two critic rounds have run, which is the pipeline's expected
  maximum; a third round requires the human's explicit decision (CLAUDE.md).
- References: C-12 to C-15; D-020, D-022; `architecture.md` 1.3.1, 1.4

## D-024: Commit 1 adopts upstream's #44343 fix (r24916, 6.1.4); supersedes the callback form in D-015
- Date: 2026-09-08
- Decided by: human (reviewer finding R-5)
- Context: D-015 fixed user deletion with OAuth rows by adding two `delete_all` calls
  to `User#remove_references_before_destroy`. The reviewer found that upstream fixed
  the same bug in #44343 ("Fix deleting a user who has authorized an OAuth2
  application fails with ActiveRecord::InvalidForeignKey"), trunk r24916
  (commit 60de97a2f), backported to 6.1-stable as 0b71fe230 and released in 6.1.4.
  Upstream's form is two associations on `User`:
  `has_many :oauth_access_grants` and `has_many :oauth_access_tokens`, both
  `:class_name => 'Doorkeeper::...'`, `:foreign_key => :resource_owner_id`,
  `:dependent => :delete_all`, placed after `has_many :reactions`.
- Decision: Commit 1 uses upstream's form verbatim and drops the callback lines.
  Supersedes the mechanism in D-015; the rest of D-015 (separate first commit, README
  "important items" entry) stands. The commit message references #43881 and #44343
  and states it is the 6.1.4 fix applied to 6.1.2, so maintainers see it vanish on
  rebase. Our unit test stays because it covers an application-less token, which
  upstream's two tests do not; upstream's tests are not copied.
- Alternatives considered: keep the callback form (works, but diverges from what
  6.1.4 ships and would conflict on rebase); rebase the whole branch onto 6.1.4 (the
  brief fixes the base at tag 6.1.2).
- Consequences: spec 3.3, the section 2 table, the README plan (section 9) and the
  work breakdown (section 12) updated; `has_many :personal_access_tokens` needs no
  `dependent` option. The implementer replaces the two callback lines currently in the
  working tree with the associations.
- References: R-5 (reviewer report, separate session); #44343; upstream commits
  60de97a2f, 0b71fe230; tag 6.1.4 `app/models/user.rb:105-109`, `test/unit/user_test.rb:239-272`

## D-025: Commit 2 adopts upstream's #44371 fix (r24992, 6.1.4) and adds only `bearer_token`
- Date: 2026-09-08
- Decided by: human + planner (same pattern as D-024)
- Context: D-012 decided to filter `key` and `bearer_token` from parameter logging
  ourselves rather than wait for #44371. Inspecting tag 6.1.4 shows #44371 shipped:
  trunk r24992, backported to 6.1-stable as ddd1ea49e, changing
  `config/application.rb:68` to
  `config.filter_parameters += [:password, :salt, :twofa_totp_key, /\Akey\z/]` and
  adding `test/unit/lib/parameter_filtering_test.rb` (five cases including the
  anti-over-filtering `keywords` check). The `key` regex is identical to ours.
- Decision: Commit 2 applies upstream's change verbatim (including `:salt` and
  `:twofa_totp_key`, which are unrelated to PATs but keep the line identical to 6.1.4)
  and appends `/\Abearer_token\z/`, the one transport Doorkeeper reads but neither
  Doorkeeper nor upstream filters. Upstream's test file is added verbatim, in its
  `test "..."` style (an accepted exception to `conventions.md`, because it is an
  upstream file), with one appended case for `bearer_token`. The separate
  `test_key_param_should_be_filtered_from_logs` planned in spec 8.3 is dropped as a
  duplicate. The commit message references #43881 and #44371 and states it is the
  6.1.4 fix applied to 6.1.2. The README's "important items" entry changes from
  "overlap with #44371" to "upstream fix applied; only `bearer_token` survives a
  rebase".
- Alternatives considered: our own minimal line (`[:password, /\Akey\z/, /\Abearer_token\z/]`),
  which conflicts on rebase and duplicates upstream's test; rebasing the branch onto
  6.1.4 (the brief fixes the base at 6.1.2).
- Consequences: spec status, 2, 4.3, 8.3, 9 and 12 updated; `architecture.md` 1.8
  updated. Unrelated 6.1.3/6.1.4 change noted and not adopted: #43698 (r24514)
  patches `Doorkeeper::AuthorizationsController#render_error` in `30-redmine.rb`; it
  concerns the authorization-code flow only and is outside this slice.
- References: D-012, D-016, D-024; #44371; upstream commit ddd1ea49e; tag 6.1.4
  `config/application.rb:68`, `test/unit/lib/parameter_filtering_test.rb`
