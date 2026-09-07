# Task context (source of truth for the goal)

## The candidate brief (TaxDome technical challenge)

Source: "Redmine API Auth - Candidate Brief" PDF, TaxDome 2026.

> Redmine is an open-source project management app on Ruby on Rails. The task is a real
> open ticket from its issue tracker: Redmine #43881. It asks for several improvements:
> personal access tokens with expiration, scopes, rate limiting, audit logging, endpoint
> control, and CORS. The poster acknowledges the scope is large, proposes a phased
> rollout, and is still waiting on maintainer guidance.
>
> The full ticket is more than ~2 hours of work. You're not expected to cover all of it.
> Choose what to build and ship that.

**Required core: personal access tokens.** The slice must implement working PATs
(pillar #1). Scopes, granular endpoint control, audit logging, and CORS are optional but
count in our favor if done well and scoped around the core. How PATs are implemented and
the trade-offs are ours to decide and to defend in the README. Reasoning matters more
than line count.

**Out of scope: rate limiting.** It is already being handled in the ticket.

### Deliverables

1. **Git repository.** Fork or new repo from `github.com/redmine/redmine`, branch off tag
   `6.1.2`. Reviewers must be able to clone, install, run migrations, and verify the
   slice. Level of testing is our call. An open MR from our branch into the branch we
   forked off.
2. **AI workflow artifacts.** Unedited logs of conversations with the LLM (exported
   chats, transcripts, prompt/response pairs) plus commit history. Do not clean up or
   summarize. Name the tools used and how they fit the workflow. Optional screen
   recording.
3. **README.** Brief. Approach, what's done, what's deferred, assumptions, how to run and
   verify. For the PAT core: how it works and the limits of the approach.

> Aim for a focused slice, not a sprawling implementation. A small slice with strong
> artifacts beats a half-finished large one. The rubric is calibrated against this.

## Redmine #43881: "Strengthen API authentication"

Tracker: Feature. Status: New. Author: Vincent Robert. Fetched 2026-09-07.

### Problem statement

Redmine API auth relies on static, non-expiring API keys with no second factor and no
access restrictions. Web access can require 2FA for admins; API access bypasses it.

Core issues: 2FA bypass; static keys without expiration; excessive privileges (no
read-only, no per-project, no per-endpoint restriction); no rate limiting; insufficient
traceability.

### The six pillars

1. **Personal access tokens.** Multiple named tokens per user; mandatory expiration;
   SHA256 hashed storage, plaintext shown once at creation; last-used tracking;
   self-service in "My account"; admin panel for org-wide oversight; backward compatible
   with the existing API key.
2. **Scoped permissions per token.** Read-only, time-logging-only, etc. Reuse the
   existing Doorkeeper OAuth2 scope mechanism. Optionally limit to projects.
3. **Rate limiting.** OUT OF SCOPE FOR US.
4. **Structured audit logging.** Queryable log: token, endpoint, method, IP, timestamp,
   status. Admin UI/API for queries and export.
5. **Granular endpoint control.** Disable specific endpoints or groups instead of the
   current all-or-nothing REST API switch.
6. **CORS configuration.** Admin-defined authorized origins.

Proposed phased rollout: start with PATs (self-service, expiration, multiple per user,
hashed storage, admin max-lifetime policy, admin overview, legacy key compatibility),
then add the rest incrementally.

### Thread highlights (what the maintainers and contributors said)

- Dennis Buehring: wants token creation restricted per role (users automating with AI
  tools are proliferating API keys).
- Related tickets: #35001 (2FA blocking username/password auth), #43938 (track API key
  last usage), #44063 (mandatory API key rotation), #44271 (OAuth scope enforcement
  gaps), #44371 (filter `key` parameter from logging, extracted by maintainer Marius
  Bălteanu for an upcoming release).
- Iurii Dremov implemented rate limiting; Marius Bălteanu steered it toward the Rails
  7.2 `rate_limit` API. This is why rate limiting is out of scope for us.
- **Bogdan Egikov** submitted a large patch covering pillars 1, 2, 4:
  - New `PersonalAccessToken` model, SHA256 hashed, `rmpat_` prefix shown once.
  - Self-service UI in My account (list/create/revoke), sudo-mode protected.
  - Last-used tracking, `personal_access_token_max_lifetime` setting.
  - Backward compatible, "same coexistence approach as the OAuth provider in 6.1.0".
  - Optional space-separated scope column, blank = full access, reuses `User#oauth_scope`.
  - Opt-in JSON audit log to `log/api_audit.log`.
- **Holger Just (core maintainer)** pushed back:
  1. PATs duplicate what OAuth applications already provide. He would prefer extending
     the existing OAuth applications so they can issue long-lived access tokens.
  2. Audit logging should be a separate patch.
  3. Each pillar is large; split into separate issues and patches for reviewability.
- Bogdan Egikov replied with why OAuth-only does not solve it today:
  - OAuth app registration is admin-only with authorization_code flow; end users cannot
    self-issue tokens for cron jobs.
  - Doorkeeper only reads `Authorization: Bearer` and `access_token`, not
    `X-Redmine-API-Key`, `?key=`, or HTTP Basic username.
  - OAuth tokens lack user-visible names, last-used tracking, admin max-lifetime policy.
  - Offered to rework as a built-in per-user OAuth application or a grant that issues
    long-lived tokens from My account if core prefers that.

### What this means for our slice

- The central design fork is the one Holger Just raised: **standalone PAT model vs.
  extending the existing OAuth/Doorkeeper machinery to issue long-lived tokens.** We
  must choose, and defend the choice in the README. The maintainer preference is on
  record and should be weighed, but the brief lets us decide.
- Maintainers want small, separable patches. Our MR should look like something they
  could actually review.
- #44371 (filtering the `key` param from logs) is being handled upstream; we should not
  duplicate it, but we may need to be aware of it if our token travels in a `key` param.
- Backward compatibility with the legacy API key is expected by everyone in the thread.
