# Feature specification: Personal access tokens for the Redmine REST API

File: `ai-workflow/specs/07_09_22_31_PAT_tokens_spec.md` (feature slug `PAT_tokens`, created 2026-09-07 22:31).

Status: **v3, approved by the human for implementation on 2026-09-07.** Critic round 1:
C-1 to C-11 accepted and applied (D-020, D-021, D-022). Critic round 2: C-12 to C-15
accepted and applied (D-023). Two critic rounds have run; planning is closed. Later
changes to this spec require a note here and a new `D-NNN` entry.

Amendments after approval:
- 2026-09-08, D-024 (reviewer R-5): section 3.3 now uses upstream's #44343 fix from
  6.1.4 (`has_many ... :dependent => :delete_all`) instead of callback lines.
- 2026-09-08, D-025: section 4.3 now applies upstream's #44371 fix from 6.1.4
  verbatim (`salt`, `twofa_totp_key`, anchored `key`, upstream test file) and adds
  only `bearer_token`; the duplicate test in 8.3 is dropped.
- 2026-09-08, D-027 (reviewer R-17): the `config/settings.yml` declaration moves from
  work-breakdown step 5 to step 3; the admin tab, its label and its tests stay in step 5.
- 2026-09-08, D-028: section 9 gains a dedicated README item for the pre-existing
  nil-user bug in `find_current_user` (locked user with a valid OAuth token → 500),
  fixed in passing by the `if user` guard.
- 2026-09-08, D-029 (human, after trying step 6): the empty token list shows a
  specific sentence (`text_personal_access_token_none`) instead of `label_no_data`;
  one functional test added (8.4). Folded into the step 6 commit (section 12), since
  step 5 was already committed.
- 2026-09-08, D-030 (reviewer R-27, step 6 review): `full_access?` additionally
  requires `expires_in.present?`, so a foreign application-less token without expiry
  and without scopes falls back to 6.1.2 behaviour instead of never-expiring full
  access. Sections 3.2, 8.1, 8.3 and 9 amended.

Owner: planner (`ai-workflow/roles/planner.md`). This document is the implementer's
contract. Anything not covered here is a question to the human, not an improvisation.
Decisions are referenced as `D-NNN` (`ai-workflow/decisions.md`); Redmine facts as
sections of `ai-workflow/architecture.md` (`arch 1.x`). Follow `ai-workflow/conventions.md`.

Rails and Redmine mechanisms are explained where they first matter, in *italics*, for
the human's benefit; the implementer can skip those.

---

## 1. Goal and non-goals

**Goal.** Give every Redmine user self-service personal access tokens (PATs) for the
REST API: several named tokens per user, each with a mandatory expiry, stored hashed,
shown in plaintext exactly once, with last-used tracking and one-click revocation from
"My account". An admin can cap the maximum lifetime. Legacy API keys keep working
unchanged, and a PAT is accepted on every transport the legacy key is accepted on.
Following the core maintainer's direction in #43881, a PAT is not a new kind of secret:
it is a Doorkeeper OAuth access token that has no application and is issued directly
by its owner (D-010).

**Non-goals (deferred, with reasons).**

- Scopes per token (pillar 2): the data path exists (`scopes` column, `User#oauth_scope`),
  the UI does not. Deferred by D-004; a core PAT has blank scopes = full access.
- Admin overview of all tokens (ticket phase one mentions it): deferred; first
  candidate add-on after the core is reviewed (D-005).
- Per-role permission to create tokens (Dennis Buehring's request), a switch to
  disable legacy keys, audit logging (pillar 4), endpoint control (pillar 5), CORS
  (pillar 6): out of the core slice.
- Rate limiting (pillar 3): forbidden (D-002).
- A JSON/XML API to manage tokens: self-service is UI only in this slice.
- Emailing the user on token creation/revocation: not in this slice.

## 2. Design decision summary

| Topic | Decision | Entry |
|---|---|---|
| Model | PAT = `Doorkeeper::AccessToken` row with `application_id NULL`, via subclass `PersonalAccessToken` | D-010 |
| Columns | `name`, `last_used_at`, `token_suffix` added to `oauth_access_tokens` | D-009, D-010 |
| Format | `rmpat_` + Doorkeeper's 43-char random part; SHA-256 at rest (Doorkeeper `hash_token_secrets`) | D-011 |
| Expiry | Mandatory, lifetime picker 7/30/60/90/180/365 days → `expires_in` seconds | D-006 |
| Admin cap | `Setting.personal_access_token_max_lifetime` (days, 0 = no cap), API tab | D-008 |
| Transports | Bearer, `access_token`/`bearer_token` params, `X-Redmine-API-Key`, `?key=`, Basic username | D-012 |
| Log filtering | Upstream #44371 fix (6.1.4) applied verbatim (`salt`, `twofa_totp_key`, anchored `key`) plus our `bearer_token` | D-012, D-016, D-025 |
| Full access | Blank scopes on an app-less token → `oauth_scope` is not set | D-010 |
| Last used | Direct column write, 1-minute throttle | D-013 |
| Revocation | `revoked_at` set, row kept; expired tokens listed until revoked | D-014 |
| UI | Page `my/api_tokens`, new controller, sidebar untouched, link in My account contextual bar | D-005 |
| Show once | Redirect after create, plaintext one hop in the flash (Array-wrapped, consumed by the first `before_action`), `no_store`, notice on refresh | D-007, D-022 |
| 2FA / password expiry | PAT equals the legacy key: not checked (Basic-username nuance documented) | D-021 |
| User deletion | Upstream #44343 fix (6.1.4) applied verbatim: `has_many` with `:dependent => :delete_all` for OAuth tokens and grants; separate first commit; README item | D-015, D-024 |

## 3. Data model

### 3.1 Migration

File: `db/migrate/20260907120000_add_personal_access_token_columns_to_oauth_access_tokens.rb`
(timestamp: any value later than `20250611092227`, use the real creation time).
Class `ActiveRecord::Migration[7.2]`, `def change`, `key: value` hash style (matches
neighbouring migrations, `arch 1.7`), no GPL header, `# frozen_string_literal: true`.

```ruby
add_column :oauth_access_tokens, :name, :string, limit: 255
add_column :oauth_access_tokens, :last_used_at, :datetime
add_column :oauth_access_tokens, :token_suffix, :string, limit: 4
```

All nullable: OAuth-flow tokens have none of these. No new index: lookups are by
`token` (unique index exists) and by `resource_owner_id` (index exists,
`20250611092155_create_doorkeeper_tables.rb:54`). Must run on PostgreSQL, MySQL, SQLite;
`add_column` with these types does.

*A migration is a versioned Ruby script that changes the database schema; Rails
records which ones ran in `schema_migrations`. `db/schema.rb` is gitignored in Redmine,
so the migration is the only description of the columns.*

### 3.2 Model `app/models/personal_access_token.rb`

```ruby
class PersonalAccessToken < Doorkeeper::AccessToken
  include Redmine::SafeAttributes

  TOKEN_PREFIX = 'rmpat_'
  LIFETIMES = [7, 30, 60, 90, 180, 365]   # days, same list as password_max_age

  belongs_to :user, :foreign_key => 'resource_owner_id'

  scope :personal, lambda {where(:application_id => nil)}
  scope :not_revoked, lambda {where(:revoked_at => nil)}

  attr_reader :lifetime_days              # virtual attribute fed by the form (C-1)

  safe_attributes 'name', 'lifetime_days'

  validates :name, :presence => true, :length => {:maximum => 255}
  validates :name, :uniqueness => {:scope => :resource_owner_id,
                                    :conditions => -> { personal.not_revoked },
                                    :case_sensitive => false}
  validates :application_id, :absence => true
  validates :lifetime_days, :inclusion => {:in => ->(t) { PersonalAccessToken.allowed_lifetimes }},
                            :on => :create
  # No separate presence validation on expires_in: it is derived from lifetime_days,
  # and a blank lifetime must yield exactly one error message (C-6).

  before_validation :set_expiry, :on => :create
  # use_refresh_token is false by default (attr_writer in the mixin); never set it.

  # Normalising writer (C-1): the form posts the String "30"; allowed_lifetimes holds
  # Integers, and `inclusion` compares with include?. Integer(value, exception: false)
  # returns nil for '', 'abc', '30abc', so those fail inclusion; 0, -1, 45 fail too.
  def lifetime_days=(value)
    @lifetime_days = Integer(value, exception: false)
  end
```

Behaviour, all to be implemented in this class (Doorkeeper base class untouched):

- `set_expiry`: `self.expires_in = lifetime_days.days.to_i` when `lifetime_days` is an
  Integer (after the writer above); otherwise leave `expires_in` nil, the inclusion
  error is the single message the user sees. `scopes` stays blank (`''`): blank = full
  access (D-010).
- `self.allowed_lifetimes`: `LIFETIMES` filtered by
  `Setting.personal_access_token_max_lifetime.to_i` when that is > 0 (keep values
  `<= cap`). If the cap is smaller than 7, the list is empty and creation is
  impossible; the form shows `text_personal_access_token_no_lifetime_available`.
- `token_generator` (instance method, overrides `access_token_mixin.rb:503`): returns
  an object whose `generate(opts)` yields
  `TOKEN_PREFIX + Doorkeeper::OAuth::Helpers::UniqueToken.generate(opts)`. The base
  `generate_token` (l.472-478) then stores `SHA256(plaintext)` and keeps the plaintext
  in `@raw_token` / `#plaintext_token`.
- `generate_token` override: `super`, then `self.token_suffix = plaintext_token.last(4)`.
- `expired?`, `revoked?`, `accessible?`, `revoke`, `expires_at` come from Doorkeeper
  (`arch 1.3.1`). Add `def active?; accessible?; end` only if a view needs the name.
- `self.track_use(access_token)`: class method taking the `Doorkeeper::AccessToken`
  found during authentication (Doorkeeper instantiates its base class, not ours).
  Returns unless `access_token.application_id.nil?`. Skips the write when
  `last_used_at` is present and `>= 1.minute.ago`; otherwise
  `where(:id => access_token.id).update_all(:last_used_at => Time.now)`. Mirrors
  `User#update_last_login_on!` (`user.rb:328-331`, D-013).
- `self.full_access?(access_token)`: `access_token.application_id.nil? &&
  access_token.expires_in.present? && access_token.scopes.all.empty?`. Used by
  `find_current_user`. The `expires_in` condition (D-030, reviewer R-27) restricts
  full access to tokens that carry the mandatory expiry our model always sets; an
  application-less token created outside this model (console, plugin, migration)
  with no `expires_in` and no scopes keeps 6.1.2 behaviour: it authenticates with an
  empty `oauth_scope` and can do nothing.

Doorkeeper 5.8 documents app-owned extra columns on access tokens via the
`custom_access_token_attributes` option (`config.rb:354`); we do not need the option
itself (it only forwards attributes through the OAuth flows), but its existence shows
that adding columns to `oauth_access_tokens` is an intended extension point (C-5).

*`Doorkeeper::AccessToken` is an ActiveRecord model owned by the gem. Subclassing it
without a `type` column means both classes read and write the same table; our class
adds validations and helpers, and `scope :personal` narrows queries to our rows.*
*`safe_attributes` is Redmine's whitelist for mass assignment: the controller writes
`token.safe_attributes = params[:personal_access_token]` and only listed attributes
are copied (`lib/redmine/safe_attributes.rb`).*
*`attr_reader :lifetime_days` plus the explicit `lifetime_days=` writer declare a plain
Ruby attribute that is not a column; the form posts it, the writer normalises it to an
Integer or nil, and the callback turns it into `expires_in`.*

### 3.3 `User` additions (`app/models/user.rb`)

- User-deletion fix (D-015, form per D-024 / reviewer R-5): adopt **upstream's fix from
  #44343** (trunk r24916, commit 60de97a2f; backported to 6.1-stable as 0b71fe230;
  released in 6.1.4) verbatim, placed after `has_many :reactions` (l.104):

  ```ruby
  has_many :oauth_access_grants, :class_name => 'Doorkeeper::AccessGrant',
           :foreign_key => :resource_owner_id, :dependent => :delete_all
  has_many :oauth_access_tokens, :class_name => 'Doorkeeper::AccessToken',
           :foreign_key => :resource_owner_id, :dependent => :delete_all
  ```

  Nothing is added to `remove_references_before_destroy`. Commit 1 message references
  both #43881 and #44343 and says it is the 6.1.4 fix applied to 6.1.2. Our unit test
  (8.2) stays, because it also covers an application-less token, which upstream's two
  tests (`test_destroy_should_delete_oauth_access_grants` / `_tokens`, 6.1.4
  `user_test.rb:239-272`) do not; do not copy upstream's tests.
- `has_many :personal_access_tokens, lambda {where(:application_id => nil)},
  :foreign_key => 'resource_owner_id'` next to `:api_token` (l.102). No `dependent`
  option: the `oauth_access_tokens` association above already deletes every token of
  the user, PATs included.

*`has_many ... :dependent => :delete_all` tells ActiveRecord to issue one `DELETE`
for the associated rows before the user row is deleted, without loading them or
running their callbacks; that is why upstream chose it over a `destroy` cascade.*

## 4. Authentication flow

### 4.1 Where a PAT can be presented

Configured in `config/initializers/30-redmine.rb` inside `Doorkeeper.configure`
(after `grant_flows`):

```ruby
access_token_methods :from_bearer_authorization,
                     :from_access_token_param,
                     :from_bearer_param,
                     lambda {|request| request.headers['X-Redmine-API-Key'].presence},
                     lambda {|request| request.params[:key].presence},
                     :from_basic_authorization
```

`Doorkeeper::OAuth::Token.from_request` accepts symbols or callables and stops at the
first non-blank value (`oauth/token.rb:7-13`); `from_basic_authorization` returns the
Basic username (l.38-42). Order matters only for which value wins when several are
present; keep Redmine's legacy transports after the standard OAuth ones.

Side effects to accept and document (C-4):

- For a plain username/password Basic request, Doorkeeper now does one extra
  `find_by(token: SHA256(username))` query that returns nil before the Basic branch
  runs. Negligible.
- `access_token_methods` is global, so Doorkeeper's own endpoints also read the new
  transports: `GET /oauth/token/info` accepts a PAT via header, `?key=` or Basic
  username. Introspection stays off (`allow_token_introspection false`).
- `POST /oauth/revoke` is **unaffected** by this slice (C-12): it reads
  `params["token"]` directly (`doorkeeper/tokens_controller.rb:148`), not
  `access_token_methods`, and `before_action :validate_presence_of_client` (l.5,
  l.64-78) refuses the request with 403 unless the caller authenticates as a
  registered `Doorkeeper::Application`. With such credentials an application-less
  token passes `authorized?` (l.102-112) and is revoked. Doorkeeper behaviour we do
  not change and do not test.

### 4.2 `find_current_user` (`app/controllers/application_controller.rb:130-158`)

Replace the API branch with:

```ruby
if user.nil? && Setting.rest_api_enabled? && accept_api_auth?
  if (key = api_key_from_request) && (user = User.find_by_api_key(key))
    # Legacy API key (unchanged behaviour)
  elsif (access_token = Doorkeeper.authenticate(request))
    # OAuth access token or personal access token
    if access_token.accessible?
      user = User.active.find_by_id(access_token.resource_owner_id)
      if user
        user.oauth_scope = access_token.scopes.all.map(&:to_sym) unless PersonalAccessToken.full_access?(access_token)
        PersonalAccessToken.track_use(access_token)
      end
    else
      doorkeeper_render_error
    end
  elsif /\ABasic /i.match?(request.authorization.to_s)
    # unchanged
```

Rules this encodes:

- **Legacy first.** A valid legacy key wins as today. An invalid value in
  `X-Redmine-API-Key`/`?key=` no longer short-circuits: it falls to Doorkeeper, then
  to Basic, then to the usual 401. A 40-hex legacy key can never match a PAT (hash
  lookup) and a PAT can never match a legacy key (`Token.find_token` regex), so there
  is no ambiguity (`arch 1.3.1`).
- **Locked/registered users.** `User.active.find_by_id` returns nil → no user → 401.
  The `if user` guard also fixes a latent `NoMethodError` on `nil.oauth_scope=` for
  locked OAuth users (test it).
- **Full access vs scoped.** App-less token with blank scopes → `oauth_scope` is not
  set, so `User#admin?` and `allowed_to?` behave exactly as with a legacy key
  (`arch 1.3.1`, D-010). A token with scopes (OAuth flow today, scoped PATs later) →
  unchanged behaviour.
- **Expired or revoked** → `doorkeeper_render_error`: 401 with
  `WWW-Authenticate: Bearer realm="Redmine", error="invalid_token", ...`. Unknown token
  → falls through → 401 with `WWW-Authenticate: Basic realm="Redmine API"` from
  `require_login`. Both are 401; the header differs. Documented as a known
  difference, not changed.
- **REST API disabled** → this whole branch is skipped; 403 as today
  (`disabled_rest_api_test.rb`).
- **2FA and password expiry (D-021).** A PAT bypasses 2FA exactly like the legacy key
  (`arch 1.10`); the ticket's "API bypasses 2FA" issue is not addressed by this slice
  and the README says so under limits. `must_change_password?` is likewise not checked
  on the PAT path. Precise statement of the difference: the legacy key presented as the
  HTTP Basic *username* goes through the Basic branch, which does check
  `must_change_password?` (l.154-157); a PAT presented the same way is consumed by
  Doorkeeper before that branch and is not checked. Header and `?key=` transport were
  never checked for either. Stated in the README limits.
- `X-Redmine-Switch-User` still applies afterwards (l.160-168).

*`find_current_user` runs before every action (`before_action :user_setup`) and sets
`User.current`; authorisation happens later in `authorize`. API requests never use the
session (`arch 1.1`).*

### 4.3 Log filtering (`config/application.rb:68`)

Adopt **upstream's #44371 fix** (trunk r24992, backported to 6.1-stable as ddd1ea49e,
released in 6.1.4) verbatim, and append our one addition on the same line (D-025):

```ruby
config.filter_parameters += [:password, :salt, :twofa_totp_key, /\Akey\z/, /\Abearer_token\z/]
```

`:salt` and `:twofa_totp_key` are upstream's, unrelated to PATs, kept so the line is
byte-identical to 6.1.4 apart from the trailing `bearer_token` entry. Also add
upstream's `test/unit/lib/parameter_filtering_test.rb` verbatim (it uses the
`test "..."` form; that is the upstream file, do not restyle it) and append one case
there for `bearer_token`. Anchored, like Doorkeeper's own filter
(`doorkeeper/engine.rb:9`), so `keywords` is not masked (upstream tests this).
Doorkeeper already filters `access_token`, `refresh_token`, `client_secret`, `code`.
Headers are not logged by Rails. (D-012, D-016, D-025)

## 5. UI

### 5.1 Routes (`config/routes.rb`, inside the `my/*` block after l.100)

```ruby
get    'my/api_tokens',     :to => 'personal_access_tokens#index',   :as => 'my_api_tokens'
post   'my/api_tokens',     :to => 'personal_access_tokens#create'
delete 'my/api_tokens/:id', :to => 'personal_access_tokens#destroy', :as => 'my_api_token'
```

*Routes map a verb and path to `controller#action`; `:as` names the path helper used
in views (`my_api_tokens_path`). Redmine declares `my/*` routes by hand (`arch 1.4`).*

### 5.2 Controller `app/controllers/personal_access_tokens_controller.rb`

```ruby
class PersonalAccessTokensController < ApplicationController
  self.main_menu = false
  before_action :read_new_token_from_flash   # first, see below (C-2, D-022)
  before_action :require_login
  before_action :require_rest_api_enabled
  require_sudo_mode :create, :destroy
```

- `read_new_token_from_flash` (**declared first**): reads
  `flash[:personal_access_token]` into `@new_token_value` (unwrapping the Array), then
  deletes the key, on every action. Two statements: `FlashHash#delete` returns the
  hash, not the value (C-15). Reason (C-2):
  `render_flash_messages` (`application_helper.rb:516-524`) prints every String flash
  value on any page, including a 403 or 500 error page that has no `no_store`. The six
  `ApplicationController` callbacks (`application_controller.rb:64`) run before this
  one but only redirect; every later failure point (login, REST API gate, sudo mode,
  exceptions) runs after the flash was consumed. Belt and braces: `create` stores the
  value wrapped in an Array (`flash[:personal_access_token] = [plaintext]`), which the
  `is_a?(String)` guard in `render_flash_messages` skips by construction, exactly as
  the backup codes store an Array of ids. The callback unwraps it.
- `require_rest_api_enabled`: `deny_access unless Setting.rest_api_enabled?`
  (`deny_access` → 403 for a logged-in user, l.317). Same gate as the Doorkeeper
  screens and the sidebar key block.
- `index`: `@tokens = User.current.personal_access_tokens.not_revoked.order(:created_at => :desc).to_a`;
  `@token ||= PersonalAccessToken.new`; `no_store if @new_token_value`.
- `create`: `@token = PersonalAccessToken.new(:user => User.current)`;
  `@token.safe_attributes = params[:personal_access_token]`; on `save`:
  `flash[:personal_access_token] = [@token.plaintext_token]`,
  `flash[:notice] = l(:notice_personal_access_token_created)`,
  `redirect_to my_api_tokens_path`. On failure: `index` then `render :action => 'index'`
  (pattern of `EmailAddressesController#create`, l.42-46).
- Flash messages are rendered with `html_safe` (C-10): every flash string in this
  controller is a static `l(:key)`; never interpolate the token name or any other user
  input into a flash message.
- Known UX limit (C-2, README): if the session expires between the POST and the
  redirected GET, `require_login` redirects without keeping the flash and the plaintext
  is lost; the user revokes and recreates. No code for this.
- Known development-only limit (C-14, README): Rails' debug error page renders a
  "session dump" (`actionpack .../rescues/_request_and_response.html.erb:7-8`), and
  the session still holds the previous request's flash until the action finishes.
  An exception on the redirected GET therefore shows the plaintext there, but only
  when `consider_all_requests_local` is true, i.e. development and test
  (`config/environments/development.rb:17`); production renders a static page. No
  code for this.
- `destroy`: `token = User.current.personal_access_tokens.not_revoked.find(params[:id])`
  (404 for another user's id or for an already revoked one, consistent with revoked
  tokens not being listed; C-8); `token.revoke`; flash
  `notice_personal_access_token_revoked`; `redirect_to my_api_tokens_path`.
- No `accept_api_auth`: this page is session-only (a token must not manage tokens).

*`require_sudo_mode` re-asks the password for these actions when an admin enabled
sudo mode in `configuration.yml`; it is a no-op otherwise and in tests (`arch 1.4`).*

### 5.3 Views

`app/views/personal_access_tokens/index.html.erb`:

1. `<%= title [l(:label_my_account), my_account_path], l(:label_personal_access_token_plural) %>`
   (breadcrumb helper, `application_helper.rb:826`, as the authorized-applications page).
2. If `@new_token_value`: a `div.box` with `text_personal_access_token_shown_once`, a
   `<pre id="new-personal-access-token">` with the plaintext, and the copy button using
   the existing Stimulus controller markup from `_sidebar.html.erb:22-33`
   (`data-controller="api-key-copy"`, target `apiKey`, `.copy-api-key-link`). The
   controller reads the target's text, so it is reusable as is.
3. `<table class="list personal-access-tokens">` (`auth_sources/index.html.erb` shape)
   with `thead`: name, token, created, expires, last used, status, empty; rows
   `id="personal-access-token-<id>"`: `name`, `…<token_suffix>` in `<code>`,
   `format_time(created_at)`, `format_time(expires_at)`,
   `last_used_at ? l(:label_personal_access_token_last_used, distance_of_time_in_words(Time.now, last_used_at)) : l(:label_never)`,
   status `l(:label_personal_access_token_expired)` if `expired?` else
   `l(:label_personal_access_token_active)`, and `td.buttons` with
   `delete_link my_api_token_path(token), {}, l(:button_revoke)` (confirm dialog is
   built in, `application_helper.rb:1600`). Empty list →
   `<p class="nodata"><%= l(:text_personal_access_token_none) %></p>` (D-029: a
   specific sentence, not the generic "No data to display"; the `nodata` class is
   kept, as `sudo_mode/new.html.erb:2` does with custom text).
4. Create form, `labelled_form_for @token, :url => my_api_tokens_path` inside
   `fieldset.box.tabular` with legend `label_personal_access_token_new`:
   `error_messages_for @token`, `f.text_field :name, :required => true, :size => 40`,
   `f.select :lifetime_days, options` where options =
   `PersonalAccessToken.allowed_lifetimes.map {|d| [l('datetime.distance_in_words.x_days', :count => d), d]}`
   (same labels as `_authentication.html.erb:26`), `:required => true`, preselected
   30 days (industry default: GitHub, GitLab, Azure DevOps) when allowed, else the
   first allowed value; `submit_tag l(:button_create)`. If
   `allowed_lifetimes` is empty, render `text_personal_access_token_no_lifetime_available`
   instead of the form.
5. `<% content_for :sidebar do %><% @user = User.current %><%= render :partial => 'my/sidebar' %><% end %>`
   exactly as `doorkeeper/authorized_applications/index.html.erb:30-33`. The legacy
   API key block therefore appears on this page unchanged (D-005).
6. `<% html_title(l(:label_personal_access_token_plural)) -%>`.

`app/views/my/account.html.erb:4`: add, after the OAuth link and under the same
`Setting.rest_api_enabled?` condition,
`link_to(sprite_icon('lock', l(:label_personal_access_token_plural)), my_api_tokens_path, :class => 'icon icon-lock')`.
(`lock` exists in the sprite; `key` is already used by the change-password link at l.3.)

No CSS unless the table needs a width tweak; if so, one rule in
`app/assets/stylesheets/application.css` under the existing `.list` rules.

### 5.4 i18n (`config/locales/en.yml` only)

Append at the end of the file (`arch 1.9`):

All of the following are verified absent from `en.yml` (C-11) and must be added:

```yaml
label_personal_access_token: Personal access token
label_personal_access_token_plural: Personal access tokens
label_personal_access_token_new: New personal access token
label_personal_access_token_active: Active
label_personal_access_token_expired: Expired
label_personal_access_token_last_used: "used %{value} ago"
label_never: Never
field_lifetime_days: Expires in
field_expires_at: Expires on
field_last_used_at: Last used
field_token_suffix: Token
button_revoke: Revoke
notice_personal_access_token_created: Personal access token created. Copy it now, it will not be shown again.
notice_personal_access_token_revoked: Personal access token revoked.
text_personal_access_token_shown_once: This is the only time the token will be shown. Store it in a safe place.
text_personal_access_token_no_lifetime_available: No token lifetime is allowed by the administrator.
text_personal_access_token_none: You have no personal access tokens yet. Create one below to access the REST API.
setting_personal_access_token_max_lifetime: Maximum lifetime of personal access tokens
```

Existing keys reused as is: `field_name`, `label_disabled` (lowercase
"disabled", as on the authentication tab), `button_create`, `text_are_you_sure`,
`datetime.distance_in_words.x_days`. Model attribute errors resolve via `field_<attr>`
(`arch 1.9`), hence `field_lifetime_days`.

## 6. Settings

`config/settings.yml`, after `rest_api_enabled`/`jsonp_enabled` (l.333-338):

```yaml
personal_access_token_max_lifetime:
  format: int
  default: 0
  security_notifications: 1
```

`app/views/settings/_api.html.erb`, third `<p>`:

```erb
<p><%= setting_select :personal_access_token_max_lifetime,
       [[l(:label_disabled), 0]] + PersonalAccessToken::LIFETIMES.collect {|days| [l('datetime.distance_in_words.x_days', :count => days), days.to_s]} %></p>
```

Semantics (D-008): 0 = no cap; otherwise the picker offers only lifetimes `<= cap`
and the model rejects anything else. Applies at creation; existing tokens are not
shortened. `security_notifications: 1` emails admins on change, like
`password_max_age`.

## 7. Optional pillars included

None. Scopes are deliberately left as a UI-only follow-up: the column, the
`oauth_scope` enforcement and the "blank = full access" rule are all in place.

## 8. Testing strategy

All tests: GPL header, `require_relative`, `def test_...` names, rocket hashes,
`fixtures :all` is global. Run in Docker: `docker compose exec app bin/rails test <file>`.
Create tokens with `PersonalAccessToken.create!(:user => User.find(2), :name => 'x', :lifetime_days => 30)`;
add `PersonalAccessToken.generate!(attributes={})` to `test/object_helpers.rb`
(pattern of `User.generate!`, l.4-15) with defaults `user: User.find(2)`,
`name: "token#{n}"`, `lifetime_days: 30`, returning the saved record (its
`plaintext_token` is readable in the test). No fixture file: hashed values in YAML
would obscure the tests.

### 8.1 Unit `test/unit/personal_access_token_test.rb`

- `test_should_generate_prefixed_token_and_store_sha256_hash`: plaintext starts with
  `rmpat_`, length 49, `token == Digest::SHA256.hexdigest(plaintext)`,
  `token_suffix == plaintext.last(4)`.
- `test_should_be_found_by_plaintext_token`: `Doorkeeper::AccessToken.by_token(plain).id`.
- `test_should_set_expires_in_from_lifetime_days`: 30 → `expires_in == 30.days.to_i`,
  `expires_at` ≈ `created_at + 30.days`.
- `test_should_require_name`, `test_should_require_lifetime`,
  `test_should_reject_unknown_lifetime` (e.g. 45, 0, -1, 'abc'),
  `test_should_reject_lifetime_above_setting_cap` with
  `with_settings(:personal_access_token_max_lifetime => 30)`,
  `test_allowed_lifetimes_should_respect_cap` (0 → all six; 90 → 7..90; 3 → empty).
- `test_name_should_be_unique_among_active_tokens_of_user` (same name for another
  user is fine; same name after revoking the first is fine; case-insensitive).
- `test_should_not_accept_application`: `application_id` set → invalid.
- `test_should_have_no_refresh_token_and_blank_scopes`.
- `test_should_be_expired_after_lifetime`: back-date `created_at`, `accessible?` false.
- `test_revoke_should_set_revoked_at`.
- `test_track_use_should_write_last_used_at_and_throttle`: nil → written; set to
  30 seconds ago → unchanged; set to 2 minutes ago → updated; an OAuth-flow token
  (with application) → never written.
- `test_full_access_should_be_true_only_for_app_less_token_with_blank_scopes`: five
  cases. True for an app-less token with `expires_in` and blank scopes. False for a
  token with an application; for an app-less token with scopes; for a token with an
  application and blank scopes; and (D-030) for an app-less token with blank scopes
  **and `expires_in` nil**, created directly with `Doorkeeper::AccessToken.create!`.

### 8.2 Unit `test/unit/user_test.rb` (additions)

- `test_destroy_should_delete_oauth_access_tokens_and_grants`: user with one
  app-less token, one token with an application, one grant → `destroy` succeeds,
  rows gone. (Commit 1, D-015.)
- `test_personal_access_tokens_association_should_exclude_application_tokens`.

### 8.3 Integration `test/integration/api_test/personal_access_token_authentication_test.rb`

Class `Redmine::ApiTest::PersonalAccessTokenAuthenticationTest < Redmine::ApiTest::Base`,
target `GET /users/current.xml` like `authentication_test.rb`:

- accepts PAT via `Authorization: Bearer`, via `X-Redmine-API-Key`, via `?key=`, via
  Basic username with any password, via `access_token` param (5 tests; assert
  `:ok` and the returned login).
- `test_should_deny_expired_pat` (back-date), `test_should_deny_revoked_pat`: 401,
  `WWW-Authenticate` starts with `Bearer`.
- `test_should_deny_pat_of_locked_user`: 401 (and no 500).
- `test_should_deny_unknown_token_on_every_transport`: 401 with Basic realm.
- `test_legacy_api_key_should_still_work_on_every_transport` (regression guard: a
  `Token` `api` row via header, `?key=`, Basic username).
- `test_full_access_pat_should_keep_admin_rights`: admin's PAT, `GET /users.xml` → 200
  and `User.current.authorized_by_oauth?` false is observable via
  `api_key` being present in `/users/current.json` for an admin, or simply assert
  200 on an admin-only endpoint.
- `test_pat_should_update_last_used_at`: nil before, present after one request.
- `test_pat_should_be_refused_when_rest_api_disabled`: `with_settings(:rest_api_enabled => '0')` → 403.
- `test_foreign_app_less_token_without_expiry_should_not_get_full_access` (D-030):
  create `Doorkeeper::AccessToken.create!(:resource_owner_id => 1, :application_id => nil,
  :expires_in => nil, :scopes => '')` for the admin, send it as Bearer:
  `GET /users/current.xml` → 200 (it still authenticates, as in 6.1.2) but
  `GET /users.xml` → 403 (empty scope, no admin), i.e. 6.1.2 behaviour, not full
  access.
- Parameter filtering is tested in upstream's `test/unit/lib/parameter_filtering_test.rb`
  (commit 2, D-025) plus our appended `bearer_token` case there; no duplicate here.

### 8.4 Functional `test/functional/personal_access_tokens_controller_test.rb`

`setup`: `@request.session[:user_id] = 2`, `Setting.rest_api_enabled = '1'`;
`teardown`: reset the setting.

- `test_index_should_list_active_and_expired_but_not_revoked_tokens` (assert_select
  rows, suffix text, "Expired" label).
- `test_index_without_tokens_should_show_specific_empty_message` (D-029):
  `assert_select 'p.nodata', :text => /no personal access tokens/` and
  `assert_select 'table.personal-access-tokens', 0`.
- `test_index_should_require_login` (302 to login), `test_index_should_deny_when_rest_api_disabled` (403).
- `test_index_should_show_create_form_with_allowed_lifetimes` and
  `..._with_cap` (`with_settings` 30 → options 7, 30 only), `..._without_form_when_no_lifetime_allowed`.
- `test_create_should_create_token_and_show_plaintext_once`: `assert_difference 'PersonalAccessToken.count'`,
  redirect to `my_api_tokens_path`, `follow_redirect!` is not available in functional
  tests → do `get :index` after the post and `assert_select 'pre#new-personal-access-token'`,
  then `get :index` again and `assert_select 'pre#new-personal-access-token', 0`;
  assert `Cache-Control` contains `no-store` on the first GET.
- `test_new_token_should_never_be_rendered_as_flash_message` (C-2): after a successful
  create, `get :index` → `assert_select '#flash_personal_access_token', 0`; and with
  `flash[:personal_access_token]` set and the REST API disabled, `get :index` → 403
  and `assert_select '#flash_personal_access_token', 0`, response body does not
  include the plaintext.
- `test_create_with_invalid_name_should_rerender_form` (`assert_select_error`),
  `test_create_with_lifetime_above_cap_should_fail`, `test_create_with_duplicate_name_should_fail`.
- `test_create_should_ignore_unsafe_attributes` (posting `expires_in`, `scopes`,
  `application_id`, `resource_owner_id` has no effect).
- `test_destroy_should_revoke_token` (`revoked_at` set, row still exists, redirect),
  `test_destroy_should_not_revoke_other_users_token` (404, `revoked_at` nil).
- Sudo mode is covered by the integration test in 8.4a, not here (the suite disables
  sudo mode globally, `test_helper.rb:40`).

### 8.4a Integration `test/integration/sudo_mode_test.rb` (additions)

Pattern: `test_update_email_address` (l.188-240): `Redmine::SudoMode.stubs(:enabled?).returns(true)`
in `setup` is already there; `log_user('jsmith', 'jsmith')`, then **`expire_sudo_mode!`**
(C-7: logging in activates sudo mode, `account_controller.rb:334`; the helper at
`sudo_mode_test.rb:273` travels past the timeout), then:

- `test_create_personal_access_token`: `post '/my/api_tokens'` with a valid form and
  no `sudo_password` → response shows `h2` "Confirm your password to continue" and
  `assert_no_difference 'PersonalAccessToken.count'`; repeat with
  `sudo_password: 'wrong'` → same; repeat with `sudo_password: 'jsmith'` →
  redirect to `/my/api_tokens`, count +1; a further `delete '/my/api_tokens/:id'`
  within the same session needs no password (sudo mode now active) and revokes.
- `test_revoke_personal_access_token`: fresh session, `delete` without password →
  confirmation page and `revoked_at` still nil.

### 8.5 Functional `test/functional/my_controller_test.rb` (addition)

- `test_account_should_link_to_personal_access_tokens_when_rest_api_enabled` and the
  negative case.

### 8.6 Functional `test/functional/settings_controller_test.rb` (addition)

- `test_api_tab_should_show_personal_access_token_max_lifetime_select` and
  `test_post_edit_should_save_personal_access_token_max_lifetime`.

### 8.7 Routing `test/integration/routing/my_test.rb` (addition)

- `should_route 'GET /my/api_tokens' => 'personal_access_tokens#index'`, POST, and
  `DELETE /my/api_tokens/1`.

### 8.8 Regression

- Existing `authentication_test.rb`, `disabled_rest_api_test.rb`, `my_controller_test.rb`,
  `user_test.rb`, `test/system/oauth_provider_test.rb` (if the system tests run in
  Docker; otherwise note it) must stay green. Full suite once before the MR.

## 9. Documentation

**README: a new file `README.md` at the repository root.** It is the candidate
brief's deliverable 3, shipped with the MR. Redmine's own `README.rdoc` stays
untouched; GitHub renders `README.md` on the fork's landing page. Contents:

- Approach: maintainer's direction, "a PAT is an application-less OAuth access token
  issued from My account"; why not a standalone model; what Doorkeeper provides.
- What is done (this spec), what is deferred (section 1 non-goals), assumptions
  (blank scope = full access; PATs bypass 2FA like legacy keys; sudo mode optional).
- How to run: `compose.yaml` header; how to verify: the curl commands from section 10
  and the test commands.
- How the PAT core works and its limits: token format, hashing, lookup, expiry,
  revocation, last-used throttle, the Bearer-style 401 on expiry, `?key=` and
  front-end logs (D-016), the #44371 fix applied from 6.1.4 with `bearer_token`
  added (D-025), 2FA and password-expiry equivalence
  with the legacy key including the Basic-username difference (D-021), the global
  `access_token_methods` effect on `/oauth/token/info` (C-4; `/oauth/revoke` is
  unaffected, C-12), the lost-token-on-session-expiry UX limit (C-2), the
  development-only error page session dump (C-14), and the
  official Doorkeeper `custom_access_token_attributes` hook as supporting evidence
  that app-owned extra columns are an intended extension point (C-5), and the
  boundary of the "blank scopes = full access" rule (D-030): it applies only to
  application-less tokens that carry an expiry, which every token issued by our
  model does; application-less tokens created by other means without an expiry keep
  6.1.2 behaviour (they authenticate with an empty scope and can do nothing).
- **Important items to discuss (D-015, D-024):** the user-deletion foreign-key fix
  is upstream's own #44343 fix from 6.1.4 applied to 6.1.2 (it disappears on rebase
  to 6.1.4+); the `filter_parameters` line is upstream's #44371 fix from 6.1.4 plus
  one `bearer_token` entry, so only that entry survives a rebase (D-025).
- **Minor finding fixed in passing (D-028):** a pre-existing bug in
  `ApplicationController#find_current_user` (6.1.2, `application_controller.rb:134-138`).
  In the OAuth branch the user is loaded with `User.active.find_by_id(...)`, which
  returns `nil` for a locked (status 3) or registered (status 2) user, and the next
  line calls `user.oauth_scope = ...` unconditionally. A blocked user presenting a
  still-valid OAuth access token therefore gets `NoMethodError` on `nil`, i.e. an
  HTTP 500, instead of being refused. Our reordered branch (spec 4.2) wraps the scope
  assignment and last-used tracking in `if user`, so the request now ends in 401 like
  any other unauthenticated request. Covered by
  `test_should_deny_pat_of_locked_user` (8.3), which fails with a 500 on the 6.1.2
  code. Not reported upstream by us at the time of writing; the README says so, so a
  maintainer can open a ticket or ask us to.
- The AI workflow: pointer to `ai-workflow/`, the four roles, logs location, tools used.

**`architecture.md` section 2 "What we built"**: owned by the implementer, one
subsection per component listed there, each referencing the `D-NNN` it implements.

## 10. Acceptance criteria

Reviewer ticks each; `$T` is a token copied from the UI, `$H` is `http://localhost:3300`.

- [ ] `bin/rails db:migrate` runs clean on the Docker PostgreSQL; `db:rollback` reverses it.
- [ ] My account shows "Personal access tokens" in the contextual bar only when the
      REST API is enabled; `my/api_tokens` returns 403 when it is disabled.
- [ ] Creating a token shows the plaintext once with a copy button; F5 shows the list
      without it and with a notice; the response carried `Cache-Control: no-store`.
- [ ] The plaintext starts with `rmpat_`; the DB row holds a 64-hex SHA-256, `name`,
      `token_suffix` = last 4 chars, `application_id` NULL, `expires_in` = days × 86400.
- [ ] `curl -H "Authorization: Bearer $T" $H/users/current.json` → 200
- [ ] `curl -H "X-Redmine-API-Key: $T" $H/users/current.json` → 200
- [ ] `curl "$H/users/current.json?key=$T"` → 200, and `log/development.log` shows `"key"=>"[FILTERED]"`
- [ ] `curl -u "$T:x" $H/users/current.json` → 200
- [ ] Admin's full-access PAT: `curl -H "Authorization: Bearer $T" $H/users.json` → 200
- [ ] After a request, the list shows "used less than a minute ago" for that token.
- [ ] Revoke → row keeps `revoked_at`, token disappears from the list, the same curl → 401
      with `WWW-Authenticate: Bearer ... error="invalid_token"`.
- [ ] Expired token (set `created_at` back in DB) → listed as "Expired"; curl → 401 Bearer.
- [ ] Legacy key: `curl -H "X-Redmine-API-Key: <40-hex>" ...` → 200, unchanged; the
      sidebar key block on My account is byte-identical to 6.1.2.
- [ ] Admin API tab shows the max-lifetime select; with 30 days, the picker offers 7 and
      30 only, and a crafted POST with 90 is rejected.
- [ ] Deleting a user who has OAuth tokens and grants succeeds (was a 500 in 6.1.2).
- [ ] `bundle exec rubocop` clean on every changed file; `bin/rails test` green;
      `bin/rails test:autoload` green (CI runs it, `conventions.md`); **and**
      `bin/rails zeitwerk:check` green (C-9, C-15: the eager-load check for a top-level
      model that subclasses a gem model configured in a `to_prepare` block;
      `test:autoload` only runs plugin autoload tests, `lib/tasks/testing.rake:118-123`).
- [ ] After a successful create, the plaintext appears only inside
      `pre#new-personal-access-token`, never in a `div.flash` (C-2).
- [ ] Diff contains no rate limiting, no scopes UI, no unrelated refactor.

## 11. Open questions (each with the default the implementer uses unless told otherwise)

1. ~~README file~~ Resolved: new `README.md` at the repository root (section 9).
2. ~~Icon~~ Resolved: `lock` (section 5.3).
3. ~~Default lifetime~~ Resolved: 30 days preselected when allowed (section 5.3).
4. ~~Sudo-mode test~~ Resolved: written as an integration test (section 8.4a).
5. ~~Cap between list values~~ Resolved: offer only list values `<= cap`; an off-list
   cap can only come from the console or a plugin (the admin UI uses the same list),
   so no extra code. Cap below 7 → empty picker, form hidden (section 5.3).

None open. The critic may reopen any of the above with evidence.

## 12. Work breakdown (one commit each, tests green after every step)

1. **Fix user deletion with OAuth tokens/grants** (`user.rb`, `user_test.rb`), in the
   upstream #44343 form. D-015, D-024.
2. **Filter `key` (and `salt`, `twofa_totp_key`) from parameter logging in the upstream
   #44371 form, plus `bearer_token`** (`application.rb`, upstream's
   `test/unit/lib/parameter_filtering_test.rb` plus one appended case). Commit message
   references #43881 and #44371 and says it is the 6.1.4 fix applied to 6.1.2.
   D-012, D-025.
3. **Migration + model + object helper + unit tests** (3.1, 3.2, 8.1,
   `User#personal_access_tokens`), **including the setting declaration in
   `config/settings.yml`** (section 6, first block) because
   `PersonalAccessToken.allowed_lifetimes` reads
   `Setting.personal_access_token_max_lifetime`, and `Setting` only defines that
   accessor from the YAML (`arch 1.5`): without it the model raises `NoMethodError`
   and the unit tests in 8.1 that exercise the cap cannot run (R-17, D-027).
   D-008, D-009, D-010, D-011.
4. **Authentication** (4.1, 4.2, integration tests 8.3, `arch` note on the locked-user guard). D-010, D-012, D-013.
5. **Admin API tab + `setting_*` i18n label + settings tests** (section 6 second block,
   8.6). The `settings.yml` declaration is already in step 3. D-008.
6. **Self-service UI** (5.1-5.4, 8.4, 8.4a, 8.5, 8.7), **including the D-029 empty-state
   change** (`text_personal_access_token_none` key, the view line, and
   `test_index_without_tokens_should_show_specific_empty_message`): step 5 was already
   committed when D-029 was decided, so the change is folded into this step's commit
   rather than a follow-up, so that commits match the spec. D-005, D-006, D-007,
   D-014, D-022, D-029.
7. **Docs**: README section, `architecture.md` "What we built", `compose.yaml` header if commands changed.

Commit messages: wiki format, reference #43881 (`conventions.md`, "Commits").
