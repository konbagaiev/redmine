# Findings

Things discovered while building the PAT slice on Redmine 6.1.2 that a maintainer or reviewer should
know about. Each entry names where it came from and what was done. The design itself is in
[README.md](README.md); the reasoning trail is in `ai-workflow/decisions.md`.

## Upstream alignment

Our base tag `6.1.2` (2026-03-17) predates two fixes the slice depends on. Both were applied as
verbatim backports so they vanish cleanly on a rebase.

1. **#44343, r24916 (6.1.4): deleting a user with OAuth tokens or grants raised
   `ActiveRecord::InvalidForeignKey`.** Every PAT owner would have hit it. Our first implementation
   was an equivalent callback fix; before it was committed, the reviewer (R-5) found the released
   upstream form (two `has_many ... :dependent => :delete_all` associations) by reading `user.rb` at
   later tags, and the first commit became a backport. Our test stays, because it also covers an application-less token, the PAT shape, which
   upstream's tests do not. Commits `bffc0fb41`, `046ed44b7`; D-015, D-024.
2. **#43986 r24609 (6.1.3) and #44371 r24992 (6.1.4): `salt`, `twofa_totp_key` and `key` filtered
   from the request log.** Both touch the same line; backported as one commit that brings
   `config/application.rb` and upstream's test file to their 6.1.4 state. Our own addition on top:
   `bearer_token`, the one transport Doorkeeper reads that nobody filtered. Commits `0567236de`,
   `eacb26f14`; D-012, D-025.

## A defect in the 6.1.2 core, still open upstream

**A locked user presenting a valid OAuth token crashed `find_current_user`.**
`User.active.find_by_id` returns `nil` for a locked user and the next line did `nil.oauth_scope =`,
so the API answered 500 instead of 401. The `if user` guard in commit `2f842b898` fixes it for OAuth
tokens and PATs alike, with `test_should_deny_pat_of_locked_user`. The unguarded line is still present
in tag 6.1.4 (`application_controller.rb:150-151`) and in trunk as of 2026-09-09 (`8de368193`).
Candidate for an upstream ticket with that test as the reproduction.

## Design corrections found in review

- **The show-once flow would have printed the token on error pages.** The first spec read the flash in
  the `index` action. The critic found that Redmine's layout renders every String flash value
  (`render_flash_messages`, `application_helper.rb`), so a 403 or 500 between the redirect and `index`
  would have displayed the plaintext with no `no-store` header. Fix: consume the flash in the
  controller's first `before_action` and store the value Array-wrapped, the same trick the 2FA
  backup-codes controller uses. Critic C-2, D-022.
- **The critic corrected its own finding.** Round 1 claimed `/oauth/revoke` would accept a PAT without
  client credentials and asked for a test pinning that. Round 2 found `validate_presence_of_client`
  on the endpoint: it answers 403 without registered-application credentials, so the claim was wrong
  and the test was dropped. C-4, C-12, D-023.
- **Foreign application-less tokens.** With the first rule "no application and no scopes means full
  access", a `Doorkeeper::AccessToken` inserted from the console or a plugin with no expiry would have
  become a never-expiring full-access credential. In 6.1.2 such a row authenticated but got an empty
  scope and could do nothing. The rule now also requires an expiry, restoring 6.1.2 behaviour for
  those rows. Raised by the human during the step 6 review, recorded as reviewer finding R-27; D-030,
  commit `91081bb33`.
- **`/oauth/token/info` and the global `access_token_methods`.** Registering the legacy transports
  for Doorkeeper is global: OAuth application tokens are now accepted via `?key=` and as the Basic
  username, and the token-info endpoint accepts a PAT. Accepted and documented rather than gated by
  the `rmpat_` prefix. D-012, README "Limits".

## Behaviour changes a maintainer will ask about

- A wrong value in `X-Redmine-API-Key` or `?key=` no longer ends the request with 401 when valid Basic
  credentials are also present; the request falls through to Doorkeeper and then Basic.
- Expired or revoked tokens answer with Doorkeeper's `Bearer ... invalid_token` challenge on every
  transport, unknown tokens with Redmine's `Basic realm`; the two are distinguishable.
- A PAT sent as the Basic username skips the `must_change_password?` check that a legacy key on the
  same transport receives, because Doorkeeper resolves it first (D-021).
