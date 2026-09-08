# Architecture

Living document. Two halves: what we have learned about Redmine that matters for this
task, and what we have built, how, and why. Keep it current; a reader who only has this
file and `decisions.md` should understand the state of the work.

## 1. Findings about Redmine 6.1.2

Status: **investigated 2026-09-07** by the planner against the checkout at the workspace
root (branch `feature/personal-access-tokens`, from tag 6.1.2, commit `1b5585ca9`).
All paths are relative to the workspace root; line numbers are from that commit.
Stack: Rails 7.2.3, Doorkeeper 5.8.2, bcrypt 3.1.22 (`Gemfile.lock`).

### 1.1 API authentication dispatch

Everything happens in `app/controllers/application_controller.rb`:

- `user_setup` (l.102) is a `before_action` that sets `User.current = find_current_user`.
- `api_request?` (l.723) is simply `%w(xml json).include? params[:format]`. There is no
  Accept-header sniffing; the URL extension decides.
- `find_current_user` (l.112-173):
  - Session, autologin cookie and Atom key are tried only when **not** `api_request?`
    (l.114-129). API requests never use the session (`test_api_request_should_not_use_user_session`).
  - The API branch (l.130) is gated by `Setting.rest_api_enabled? && accept_api_auth?`,
    then tries, in this order:
    1. `api_key_from_request` (l.728): `params[:key]` first, then header
       `X-Redmine-API-Key`. Resolved with `User.find_by_api_key(key)` (l.133).
    2. `Doorkeeper.authenticate(request)` (l.134): OAuth bearer token. If
       `access_token.accessible?` the user is loaded with `User.active.find_by_id` and
       `user.oauth_scope = access_token.scopes.all.map(&:to_sym)` is set; otherwise
       `doorkeeper_render_error`.
    3. HTTP Basic (l.142): only if `request.authorization` starts with `Basic`.
       `User.try_to_login(username, password)` first; if that user has 2FA active the
       request is rejected with 401 "HTTP Basic authentication is not allowed. Use API
       key instead" (l.147-150). Then `user ||= User.find_by_api_key(username)`, i.e. the
       API key can be sent as the Basic username with any password (l.152).
       `must_change_password?` is checked with a 403 **only inside this Basic branch**
       (l.154-157); the header/param API-key path does not check it.
  - Admin impersonation: header `X-Redmine-Switch-User` (l.160-168), admins only, 412 on
    invalid/locked target.
  - `user.remote_ip = request.remote_ip` is stored ephemerally (l.171).
- `accept_api_auth` (class method, l.646) stores a per-controller list of actions in
  `accept_api_auth_actions`; `accept_api_auth?` (l.654) checks the current action. An API
  key is therefore only honoured on actions that opt in (e.g. `MyController` opts in
  `:account` only, `app/controllers/my_controller.rb:26`).
- `require_login` (l.273) for `format.api` returns `401` with
  `WWW-Authenticate: Basic realm="Redmine API"` when the API is enabled and the action
  accepts API auth, otherwise `403` (l.292-298). This is what "disabled REST API" looks
  like from outside (`test/integration/api_test/disabled_rest_api_test.rb`).
- CSRF is skipped for `api_request?` (`verify_authenticity_token`, l.43).
- `require_admin_or_api_request` (l.606) and `render_api_ok/head/errors` (l.761-780) are
  the helpers API controllers use.
- `Setting.rest_api_enabled?` is a plain setting (`config/settings.yml:333`, default 0,
  `security_notifications: 1`), toggled on the admin "API" tab
  (`app/views/settings/_api.html.erb`). It also gates the OAuth admin menu
  (`lib/redmine/preparation.rb:283-284`), the "Authorized applications" link and the
  API-key block in My account (`app/views/my/account.html.erb:4`, `_sidebar.html.erb:21`).

There is no `EnabledModule` involvement in API auth; modules only matter in
`Project#allows_to?` inside `User#allowed_to?`.

### 1.2 Legacy API key: `User#api_key`, `Token`, the `tokens` table

- `app/models/token.rb`: one generic table for every kind of secret. Actions are
  registered with `add_action name, max_instances:, validity_time:` (l.39-45):
  `api` (max 1, never expires), `autologin` (10), `feeds` (1), `recovery`, `register`,
  `session` (10), `twofa_backup_code` (10). `add_action` accepts only those two options
  (`assert_valid_keys`, l.33); there is no per-row expiry, name, or last-used concept.
- `before_create :delete_previous_tokens, :generate_new_token` (l.24): with
  `max_instances: 1` for `api`, creating a second API token silently deletes the first
  (l.135-146). **Multiple named API tokens per user cannot be expressed with `Token`
  without changing its contract.**
- `Token.generate_token_value` = `Redmine::Utils.random_hex(20)` (l.128-130 →
  `lib/redmine/utils.rb:48`, `SecureRandom.hex(20)`), i.e. a 40-char lowercase hex string.
- `Token.find_token(action, key, validity_days=nil)` (l.113-126): rejects keys that do
  not match `/\A[a-z0-9]+\z/i`, does `Token.find_by(action:, value:)` on the **plaintext**
  value, then `secure_compare`, requires `token.user`. `find_user` / `find_active_user`
  (l.96-109) wrap it; `find_active_user` additionally requires `user.active?`
  (`status == 1`; locked/registered users are refused).
- **Token values are stored in plaintext.** Nothing hashes them; the unique index is on
  the raw value.
- `User#api_key` (`app/models/user.rb:443-448`) lazily creates the `api` token and
  returns its value; `has_one :api_token` (l.102) is the association.
  `User.find_by_api_key(key)` (l.553) = `Token.find_active_user('api', key)`.
- The `api` token is exposed via `app/views/users/show.api.rsb:14` (to admins, and to the
  user themself unless authorised via OAuth) and `app/views/my/account.api.rsb:10`.
- `User#destroy_tokens` (l.962-967) deletes `recovery`, `autologin`, `session` tokens on
  password change / deactivation / 2FA activation, but **not** `api`.
  `remove_references_before_destroy` (l.993) deletes all tokens on user destroy.
- Schema of `tokens` (no `db/schema.rb`: it is gitignored, `.gitignore:20`, and
  `db/` contains only `migrate/`):
  - `db/migrate/001_setup.rb:191-196`: `user_id integer not null default 0`,
    `action string(30)`, `value string(40)`, `created_on datetime`.
  - `20091017213444_add_missing_indexes_to_tokens.rb`: index on `user_id`.
  - `20130201184705_add_unique_index_on_tokens_value.rb`: unique index `tokens_value`.
  - `20151024082034_add_tokens_updated_on.rb`: `updated_on timestamp`.
  - Consequences: `value` is limited to 40 chars (a SHA-256 hex digest is 64), and
    `action` to 30. Reusing `tokens` for hashed PATs would require altering the table.
- Fixtures: `test/fixtures/tokens.yml` has only a `register` and a `recovery` token; no
  `api` token fixture exists. Tests create them with
  `Token.create!(:user => user, :action => 'api')`.
- Existing tests: `test/unit/token_test.rb` (find_token/find_active_user, expiry,
  max_instances), `test/unit/user_test.rb:857` (`test_api_key_should_not_be_generated_twice`),
  `test/functional/my_controller_test.rb:811-834` (show/reset API key),
  `test/integration/api_test/users_test.rb:277-286` (api_key visibility in the API).

### 1.3 OAuth provider (Doorkeeper, since 6.1.0)

- Config: `config/initializers/30-redmine.rb:23-81` (the `doorkeeper.rb` initializer is
  an empty placeholder). Key points:
  - `grant_flows ['authorization_code']` only; `use_refresh_token`; PKCE enabled by
    migration `20250611092227_enable_pkce.rb`.
  - `hash_token_secrets` (Doorkeeper default strategy = SHA-256 hex of the token) and
    `hash_application_secrets using: '::Doorkeeper::SecretStoring::BCrypt'`. So
    **OAuth access tokens are already hashed at rest**, unlike the legacy API key.
  - `access_token_expires_in` is left at the Doorkeeper default (2 hours, commented out
    l.34-37). Setting it to `nil` would make tokens non-expiring globally, not per token.
  - `default_scopes(*Redmine::AccessControl.public_permissions.map(&:name))` and
    `optional_scopes(*(Redmine::AccessControl.permissions.map(&:name) << :admin))`
    (l.51-52): **scopes are exactly the permission names from `Redmine::AccessControl`
    plus `:admin`**. `enforce_configured_scopes` rejects anything else.
  - `resource_owner_authenticator` requires login and `Setting.rest_api_enabled?`;
    `admin_authenticator` requires REST API enabled and `User.current.admin?` (l.66-80).
    Application management is admin-only.
  - `Doorkeeper::ApplicationsController` gets `require_sudo_mode :create, :show,
    :update, :destroy`; `AuthorizationsController` `:create, :destroy` (l.110-116).
  - Routes: `config/routes.rb:21-22` `use_doorkeeper do controllers :applications =>
    'oauth2_applications' end`.
- Bearer token resolution for API requests is the single call
  `Doorkeeper.authenticate(request)` in `find_current_user` (l.134). Doorkeeper's
  default `access_token_methods` are `from_bearer_authorization`,
  `from_access_token_param`, `from_bearer_param` (Authorization: Bearer, `access_token=`,
  `bearer_token=`). Not verified locally (gem is not vendored in the checkout); this
  matches Bogdan Egikov's statement in the ticket. `X-Redmine-API-Key`, `?key=` and
  Basic are not read by Doorkeeper.
- Scope enforcement lives in the `User` model, not the controller:
  - `attr_writer :oauth_scope` (`user.rb:115`); `authorized_by_oauth?` = `!@oauth_scope.nil?`
    (l.746).
  - `admin?` (l.736-743) is only true under OAuth if the scope includes `:admin`.
  - `allowed_to?` (l.759-795) passes `@oauth_scope` into `Role#allowed_to?(action, scope)`
    (`app/models/role.rb:204-210`), and `Role#allowed_permissions(scope)` (l.304-311)
    intersects the role's permissions (plus public permissions) with the scope array.
    So a scope is a **filter (logical AND) over the user's real permissions**; it can
    never grant more than the user has. Blank scope (`nil`) = unrestricted.
  - This is the "reuse `User#oauth_scope`" hook Bogdan's patch relies on: set
    `user.oauth_scope = [...]` on a PAT-authenticated user and the existing checks apply.
  - Unit tests: `test/unit/user_test.rb:1401-1460` (`test_should_recognize_authorized_by_oauth`,
    `test_admin_should_be_limited_by_oauth_scope`, `test_oauth_scope_should_limit_*`).
- Tables (`db/migrate/20250611092155_create_doorkeeper_tables.rb`,
  `ActiveRecord::Migration[7.2]`):
  - `oauth_applications`: `name`, `uid` (unique), `secret`, `redirect_uri text not null`,
    `scopes text not null`, `confidential bool default true`, timestamps.
  - `oauth_access_grants`: `resource_owner_id` (FK users), `application_id` (FK, not
    null), `token` (unique), `expires_in int not null`, `redirect_uri`, `created_at`,
    `revoked_at`, `scopes`, plus `code_challenge`/`code_challenge_method` (PKCE).
  - `oauth_access_tokens`: `resource_owner_id` (FK users, nullable), `application_id`
    (FK, **nullable**), `token` (unique, hashed), `refresh_token` (unique),
    `expires_in int` (nullable = never expires, relative to `created_at`), `revoked_at`,
    `created_at`, `scopes text`, `previous_refresh_token`. No `name`, no `last_used_at`.
- UI/controllers: `app/controllers/oauth2_applications_controller.rb` subclasses
  `Doorkeeper::ApplicationsController` only to force public permissions into `scopes`
  (l.24-37). Views are overridden under `app/views/doorkeeper/{applications,
  authorizations,authorized_applications}/`. Admin menu entry `:applications`
  (`lib/redmine/preparation.rb:283-287`, caption
  `doorkeeper.layouts.admin.nav.applications` from the `doorkeeper-i18n` gem). Users
  see "Authorized applications" from My account (`account.html.erb:4`).
- Tests: the only end-to-end OAuth test is `test/system/oauth_provider_test.rb`
  (Capybara, real authorization_code flow with a local WEBrick redirect). There is **no
  functional or integration test of bearer-token API auth** in
  `test/integration/api_test/authentication_test.rb`, and no `oauth_*` fixtures.
- Relevant i18n keys: `label_oauth_*`, `text_oauth_*` (`config/locales/en.yml:1171-1174,
  1365-1369`); the rest comes from `doorkeeper-i18n`.

What this says about "extend OAuth" vs "standalone PAT":

- What already exists in OAuth and would be reused by extending it: hashed token storage,
  `expires_in`/`revoked_at`, scopes tied to real permissions, `accessible?` semantics,
  admin UI for applications.
- What is missing for the PAT use case: (a) the only grant flow is `authorization_code`
  with admin-registered applications, so a user cannot self-issue a token from My
  account; (b) `oauth_access_tokens` has no name/last-used columns and `application_id`
  would have to be nil or point at a synthetic "personal" application; (c) expiry is a
  global config value, not per token; (d) Doorkeeper only reads `Bearer`/`access_token`,
  so backward-compatible transport (`X-Redmine-API-Key`, `?key=`, Basic) would need a
  custom `access_token_methods` or a pre-resolution step in `find_current_user` anyway;
  (e) Doorkeeper's model classes are gem-owned. **Resolved (1.3.1, D-010):** no
  monkey-patch is needed. Extra columns are added by a Redmine migration (the app owns
  the schema of the Doorkeeper tables), validations live in a Redmine subclass
  `PersonalAccessToken < Doorkeeper::AccessToken`, and Doorkeeper 5.8 itself documents
  app-owned extra token columns via `custom_access_token_attributes` (`config.rb:354`).
  Points (a)-(d) are addressed by self-issue from My account, the new columns, per-row
  `expires_in`, and configurable `access_token_methods` respectively (1.3.1).

### 1.3.1 Verified: application-less Doorkeeper access tokens (probe, 2026-09-07)

Planner probe run in the container (`bin/rails runner` + `curl`), rows deleted afterwards.
Gem source read at `doorkeeper-5.8.2` (installed on the host via `bundle install`).

- `Doorkeeper::AccessToken.new(resource_owner_id:, application_id: nil, expires_in:,
  scopes:, use_refresh_token: false)` is **valid and saves**. `belongs_to :application`
  is `optional: true` (`lib/doorkeeper/orm/active_record/mixins/access_token.rb:13-15`);
  the only model validations are `token` presence/uniqueness and `refresh_token`
  uniqueness when used (l.17-18). No validation on `scopes`.
- `before_validation :generate_token, on: :create` (l.25) calls the configured
  generator (`UniqueToken.generate` → `SecureRandom.urlsafe_base64(32)`, 43 chars) and
  stores `SHA256(plaintext)` because Redmine enables `hash_token_secrets`
  (`access_token_mixin.rb:472-478`, `secret_storing/sha256_hash.rb`). The plaintext
  is available once via `#plaintext_token` on the freshly created object.
- Lookup: `Doorkeeper::AccessToken.by_token(plain)` = `find_by_plaintext_token`
  (hashes, then `find_by`; `models/concerns/secret_storable.rb:42-47`). Verified: found.
- Expiry is **per row**: `expires_in` seconds relative to `created_at`
  (`models/concerns/expirable.rb`); `expired?`, `accessible?` (= not expired and not
  revoked), `revoke`, `revoked?` all work on an app-less token. Verified by back-dating
  `created_at`. The global `access_token_expires_in` only feeds the OAuth flows.
- A 43-char base64url token fails the legacy `Token.find_token` regex
  (`/\A[a-z0-9]+\z/i`), so a Doorkeeper token can never collide with or be looked up
  as a legacy API key. Verified: `Token.find_token('api', plain)` → nil.
- `Doorkeeper::Application.authorized_for(user)` selects distinct `application_id`
  from active tokens; app-less tokens do not appear on "Authorized applications".
  Verified: count 0.
- **HTTP, no code changes:** `Authorization: Bearer <token>` on `GET /users/current.json`
  → 200 through the existing branch (`application_controller.rb:134-138`); with scope
  `admin` the admin-only `GET /users.json` → 200. An expired token → 401 with
  `WWW-Authenticate: Bearer realm="Redmine", error="invalid_token",
  error_description="The access token expired"` (Doorkeeper's error shape via
  `doorkeeper_render_error`, not Redmine's Basic realm).
- **Legacy transports do not reach Doorkeeper:** `X-Redmine-API-Key: <token>` → 401,
  Basic with token as username → 401. Two reasons: (1) Doorkeeper's default
  `access_token_methods` are `from_bearer_authorization`, `from_access_token_param`,
  `from_bearer_param` (`config.rb:586-591`); (2) in `find_current_user` the legacy
  branch `if (key = api_key_from_request)` wins whenever the header/param is present,
  and Doorkeeper sits in an `elsif`, so it is never consulted for those transports.
  Fixable: `Doorkeeper::OAuth::Token.from_request` accepts symbols **or callables**
  (`oauth/token.rb:7-13`), and `from_basic_authorization` (returns the Basic username,
  l.38-42) already exists; so `access_token_methods` can be configured in
  `config/initializers/30-redmine.rb` with two lambdas for the header and `?key=`
  plus `:from_basic_authorization`. The branch order in `find_current_user` must then
  become "legacy key lookup, and if that returns nil, Doorkeeper".
- Scopes: `scopes` is a space-separated string; `#scopes.all` returns an array.
  Redmine sets `user.oauth_scope = scopes.all.map(&:to_sym)`. With an **empty** scope
  list `Role#allowed_permissions([])` is unrestricted (`scope.present?` is false,
  `role.rb:304-311`) **but** `User#admin?` becomes false (`user.rb:737-739`), i.e. a
  blank-scope token would silently drop admin. A "full access" PAT therefore needs
  either the full enumerated scope list (frozen at creation; permissions added later
  by plugins would be missing) or a special case that skips `oauth_scope=` for
  app-less tokens with blank scopes (Bogdan Egikov's "blank = full access").
- `users/show.api.rsb:14` hides `api_key` from a non-admin user authenticated via
  OAuth (`authorized_by_oauth?`); a scoped PAT inherits that.
- **Pre-existing gap:** `oauth_access_tokens.resource_owner_id` has a foreign key to
  `users` (`20250611092155_create_doorkeeper_tables.rb:62-66`) and
  `User#remove_references_before_destroy` (`user.rb:971-993`) does not delete
  Doorkeeper rows. Verified on PostgreSQL: destroying a user who has any access token
  raises `ActiveRecord::InvalidForeignKey`. Any design that stores PATs in this table
  must delete them there, which also fixes it for OAuth tokens. Fixed upstream as
  #44343 (r24916, backported to 6.1-stable in r24939, released in 6.1.4); our branch
  carries that fix as its first commit (section 2.1).
- Doorkeeper's own endpoints and `access_token_methods`: `GET /oauth/token/info`
  resolves its token with `OAuth::Token.authenticate(request, *access_token_methods)`
  (`doorkeeper/rails/helpers.rb:72-76`), so any transport we add there applies to it
  too; its JSON tolerates a nil application (`application.try(:uid)`,
  `access_token_mixin.rb:352`). `POST /oauth/revoke` reads `params["token"]` directly
  (`tokens_controller.rb:148`) and is guarded by `validate_presence_of_client`
  (l.5, l.64-78): without credentials of a registered `Doorkeeper::Application` it
  answers 403 and revokes nothing; with them, an application-less token passes
  `authorized?` (l.102-112). Neither endpoint is changed by the PAT slice.
- Subclassing: `Doorkeeper::AccessToken` is a plain `ActiveRecord::Base` subclass
  including a mixin (`orm/active_record/access_token.rb`). The table has no `type`
  column, so a `PersonalAccessToken < Doorkeeper::AccessToken` subclass shares the
  table without STI and can carry its own validations and scope
  (`where(application_id: nil)`); Doorkeeper's own lookup still instantiates the base
  class. Extra columns (`name`, `last_used_at`, suffix) are added by a Redmine
  migration; the app owns the schema of these tables.

### 1.4 My account

- `app/controllers/my_controller.rb`: `before_action :require_login`,
  `accept_api_auth :account` (l.26), `require_sudo_mode :account, only: :put` and
  `require_sudo_mode :reset_atom_key, :reset_api_key, :show_api_key, :destroy` (l.28-29).
  `show_api_key` (l.134) just sets `@user`; `reset_api_key` (l.139-149) destroys the
  existing `api` token, calls `User.current.api_key` to regenerate, flashes
  `notice_api_access_key_reseted`, redirects to `my_account_path`.
- Routes (`config/routes.rb:92-100`): `match 'my/account'` (get/put), `get 'my/api_key'`
  → `show_api_key` as `my_api_key`, `post 'my/api_key'` → `reset_api_key`,
  `post 'my/atom_key'`, `match 'my/password'`, `my/account/destroy`. All `my/*` routes are
  declared by hand (no `resources`), and `MyController` is a single controller with
  `self.main_menu = false`.
- Views (`app/views/my/`): `account.html.erb` is a two-column `labelled_form_for :user`
  with a `.contextual` bar (change password, OAuth authorized applications, hook
  `view_my_account_contextual`) and hooks `view_my_account`, `view_my_account_preferences`.
  The right sidebar is `content_for :sidebar` → `_sidebar.html.erb`, which renders the
  Atom key block and, if `Setting.rest_api_enabled?`, the "API access key" block: Show
  link (`remote: true`, served by `show_api_key.js.erb` which injects `@user.api_key`
  into `<pre id="api-access-key">`), a copy button (Stimulus `api-key-copy` controller,
  `test/system/api_key_copy_test.rb`), "created N ago" text and a Reset link (POST).
  `show_api_key.html.erb` is the non-JS fallback page. `account.api.rsb` exposes
  `api_key` in `GET /my/account.json`.
- Sudo mode (`lib/redmine/sudo_mode.rb`): `require_sudo_mode` class method (l.182-187)
  installs a `SudoRequestFilter` before_action; the filter **skips API requests**
  (l.158-159, `test_sudo_mode_should_skip_api_requests`) and is a no-op unless
  `Redmine::Configuration['sudo_mode']` is truthy (`enabled?`, l.232; **off by default**,
  see `config/configuration.yml.example:165-171`) and the user is logged in. Timeout
  `sudo_mode_timeout` minutes, default 15 (l.237-240). When active it re-renders
  `sudo_mode/new` with the original params as hidden fields. `test/test_helper.rb:40`
  calls `Redmine::SudoMode.disable!` globally; `test/integration/sudo_mode_test.rb`
  re-enables it per test. So "sudo-protected" in a spec means: declare it with
  `require_sudo_mode`, and it only bites when an admin turned sudo mode on.
- Flash rendering: the layout prints flash entries through
  `ApplicationHelper#render_flash_messages` (`app/helpers/application_helper.rb:516-524`),
  the only flash iterator in `app/` and `lib/` (grep `flash.each`). It skips any value
  that is not a String (`next unless v.is_a?(String)`) and renders the rest with
  `html_safe` inside `div.flash#flash_<key>`. Consequences: a non-String flash value
  (Array) is never printed by the layout (the backup-codes controller relies on this,
  `twofa_backup_codes_controller.rb:57`), and flash strings must never contain user
  input. `FlashHash#delete` returns the hash, not the value.
- Development error page: with `consider_all_requests_local = true`
  (`config/environments/development.rb:17`, also test) Rails' debug page includes a
  session dump (`actionpack rescues/_request_and_response.html.erb:7-8`), which still
  holds the previous request's flash until the action completes. Production renders
  a static page.
- Menus: `Redmine::MenuManager` (`lib/redmine/menu_manager.rb`), maps defined in
  `lib/redmine/preparation.rb` (`:top_menu` l.164, `:account_menu` l.175 with
  `:my_account`, `:admin_menu` l.242). `menu_item :id, :only => [...]` at controller
  level selects the highlighted item (`menu_manager.rb:46-53`). The My account sidebar
  is not a menu; it is the `_sidebar.html.erb` partial.

### 1.5 Settings

- Declared in `config/settings.yml` (one YAML key per setting, options: `default`,
  `format: int`, `serialized: true`, `security_notifications: 1`). Examples relevant to
  us: `rest_api_enabled` (l.333, default 0), `jsonp_enabled` (l.336), `password_max_age`
  (l.54, `format: int`, default 0 = disabled; the "0 means off" idiom), `autologin`
  (l.167, int days), `session_lifetime`/`session_timeout` (l.67-75, minutes),
  `login_required`, `twofa`.
- `app/models/setting.rb`: `load_available_settings` (l.322) reads the YAML at class load
  and calls `define_setting` (l.303-320), which generates `Setting.xxx`,
  `Setting.xxx?` (= `to_i > 0`) and `Setting.xxx=`. Values are cached per process and
  `Setting.check_cache` runs each request (`application_controller.rb:104`).
  `Setting.set_all_from_params` (l.137) validates via `validate_all_from_params` (l.161)
  and sends security notifications for settings flagged `security_notifications`.
- Admin UI: `SettingsController#edit` (`app/controllers/settings_controller.rb:36-62`,
  `require_admin`, `require_sudo_mode :index, :edit, :plugin`), tabs from
  `SettingsHelper#administration_settings_tabs` (`app/helpers/settings_helper.rb:21-42`),
  partials in `app/views/settings/_*.html.erb`. The "API" tab is
  `app/views/settings/_api.html.erb` (two check boxes, `form_tag({:action => 'edit',
  :tab => 'api'})`). Helpers: `setting_check_box`, `setting_text_field`,
  `setting_select` etc. (`settings_helper.rb:58-113`). Labels come from
  `setting_<name>` keys in `en.yml` (e.g. `setting_rest_api_enabled`, l.492).
- Tests use `with_settings(rest_api_enabled: 1) { ... }` (`test/test_helper.rb:97`) or
  assign `Setting.rest_api_enabled = '1'` directly.
- `Redmine::Configuration` (`lib/redmine/configuration.rb`) is the separate
  `config/configuration.yml` layer (sudo mode, secret token, cookie names); not the
  place for per-installation feature settings.

### 1.6 Tests

- Layout (`test/`): `unit/` (models and `unit/lib/redmine/*`), `functional/`
  (controller tests, `Redmine::ControllerTest`), `integration/` (Rails integration
  tests, `Redmine::IntegrationTest`), `integration/api_test/` (one file per API resource,
  `Redmine::ApiTest::Base`), `integration/routing/`, `system/` (Capybara),
  `fixtures/`, `helpers/`, `test_helper.rb`, `object_helpers.rb` (`User.generate!`
  etc.). Minitest; `fixtures :all` is declared once on `ActiveSupport::TestCase`
  (`test_helper.rb:59`), so every fixture is available in every test (corrected per
  critique C-5; some older test files still list `fixtures :users, ...` redundantly).
- `test/test_helper.rb`:
  - `Redmine::IntegrationTest#log_user(login, password)` (l.412) and
    `#credentials(user, password=nil)` (l.428) → `{'HTTP_AUTHORIZATION' => Basic ...}`
    (password defaults to the login).
  - `Redmine::ApiTest::Base` (l.437-444) sets `Setting.rest_api_enabled = '1'` in setup
    and back to `'0'` in teardown. `API_FORMATS = %w(json xml)`.
  - `with_settings` (l.97), `uploaded_test_file` (l.69).
- `test/integration/api_test/authentication_test.rb` is the reference for API auth
  behaviour: 401 + `WWW-Authenticate` without credentials; Basic username/password;
  Basic refused when 2FA active; API key as Basic username; `?key=`;
  `X-Redmine-API-Key`; wrong-action token refused; non-Basic `Authorization` header
  ignored; invalid UTF-8; session not used; `X-Redmine-Switch-User`. All use
  `GET /users/current.xml`. A PAT test file can mirror it exactly.
- `test/integration/api_test/disabled_rest_api_test.rb`: 403 for every credential type
  when `rest_api_enabled` is off.
- `test/functional/my_controller_test.rb`: logs in as user 2 (`jsmith`) in setup;
  `test_show_api_key`, `test_reset_api_key_*` at l.811-834.
- `test/integration/routing/my_test.rb` asserts the hand-written `my/*` routes.
- Fixtures: `users.yml` (`users_001` = `admin`/`admin`, id 1, admin; `users_002` =
  `jsmith`/`jsmith`, id 2; `users_005` = `dlopper2`, status 3 locked; `users_006` =
  anonymous, status 0), `tokens.yml` (2 rows, no `api` token). Password hashes are
  SHA1(salt+SHA1(password)) (`User#check_password?`, `user.rb:335-341`).
- `test/unit/lib/redmine/i18n_test.rb:206` `test_locales_validness` only checks every
  locale file loads; missing keys fall back to `en` (`config.i18n.fallbacks = true`,
  `config/application.rb:60`), so adding keys to `en.yml` only is sufficient for tests.

### 1.7 Migrations and schema

- Newest files in `db/migrate/` are `20250423065135_create_reactions.rb`,
  `20250530185658_ensure_wiki_tablesort_setting_is_stored_in_db.rb`,
  `20250611092155_create_doorkeeper_tables.rb`, `20250611092227_enable_pkce.rb`.
  Convention: `YYYYMMDDHHMMSS_snake_case.rb`, `class X < ActiveRecord::Migration[7.2]`,
  `def change`, `t.references`/`add_index`/`add_foreign_key`, `t.timestamps null: false`
  where Rails-style timestamps are used (the old core tables use `created_on`/`updated_on`).
  Most 2024-2025 migrations have no `# frozen_string_literal` header (only
  `enable_pkce.rb` does), and no license header.
- `db/schema.rb` is **not** committed (`.gitignore:20`); `db/` only has `migrate/`.
  Reviewers verify with `bin/rails db:migrate`.
- Redmine supports MySQL, PostgreSQL and SQLite; migrations sometimes branch on
  `Redmine::Database.mysql?` (`20241103150135_change_settings_value_limit.rb`).

### 1.8 #44371 (filtering `key` from logs)

- `config/application.rb:68`: `config.filter_parameters += [:password]` is the only
  filter. There is no `config/initializers/filter_parameter_logging.rb`. Nothing in 6.1.2
  filters `key`, `X-Redmine-API-Key` or `access_token`. A PAT sent via `?key=` would be
  logged in plaintext by Rails' request log today. Upstream is handling this in #44371.
  **Superseded by D-012 (2026-09-07):** we filter `key` and `bearer_token` ourselves now
  (anchored regexes next to `:password`), and the README notes the overlap so
  maintainers can drop whichever lands second.

### 1.9 i18n

- All English strings are in `config/locales/en.yml` (flat keys under `en:`).
  Blocks by prefix (first occurrence; later additions are appended at the end of the
  file, l.1418-1461, regardless of prefix): `notice_*` (flash messages, l.160-201),
  `field_*` (model attribute labels, from l.285: `field_name` l.285, `field_created_on`
  l.297, `field_login` l.329, `field_last_login_on` l.332), `setting_*` (from l.433,
  `setting_rest_api_enabled` l.492), `label_*` (from l.628; `label_api_access_key`
  l.1030, `label_api` l.1127, `label_oauth_*` l.1171), `button_*` (l.1181-1245,
  `button_delete` l.1188, `button_create` l.1189), `text_*` (from l.1262,
  `text_are_you_sure` l.1279).
- ActiveRecord attribute names in `errors.full_messages` resolve through
  `ApplicationRecord.human_attribute_name` (`app/models/application_record.rb:23-32`),
  which tries `field_<model>_<attr>` then `field_<attr>` (strips `_id`). So a new
  model's attributes need `field_*` keys, e.g. `field_expires_at`, or the existing
  `field_name` is reused automatically.
- `lib/tasks/locales.rake`: `rake locales` = `locales:update` (adds new top-level
  `en.yml` keys to every other locale file, copying the English text) +
  `locales:check_interpolation`. Also `locales:add_key`, `locales:remove_key`,
  `locales:dup`. Core commits usually add keys only to `en.yml` (other locales fall
  back), so we do not need to touch the other 50 files.

### 1.10 Other things a PAT design must respect

- `safe_attributes` (`lib/redmine/safe_attributes.rb:33-84`): the Redmine idiom for
  mass assignment; `model.safe_attributes = params[:model]` with optional
  `:if => lambda {|obj, user| ...}` guards. New models should declare
  `safe_attributes 'name', 'expires_at', ...` rather than use strong params.
- `User#allowed_to?` / `Redmine::AccessControl` (`lib/redmine/access_control.rb`):
  permissions are declared in `lib/redmine/preparation.rb` via
  `map.permission :name, {controller => [actions]}, :public => true, :read => true`.
  `Permission#public?` marks permissions everyone has; `public_permissions` are what
  Doorkeeper uses as `default_scopes`. API auth does not interact with permissions
  beyond setting `User.current`; authorization happens later in `authorize` /
  `authorize_global` (`application_controller.rb:322-342`).
- `users.status` (`app/models/principal.rb:24-27`): 0 anonymous, 1 active,
  2 registered, 3 locked. `User.active` scope and `Principal#active?` (l.146).
  `Token.find_active_user` and the OAuth branch both refuse non-active users, so a
  PAT lookup must do the same.
- 2FA: `User#twofa_active?` (l.398) blocks Basic username/password only; API keys
  bypass 2FA by design (this is the "2FA bypass" the ticket complains about).
  `User#must_activate_twofa?` (l.402) and `check_twofa_activation` are session-only
  redirects and never fire for API requests. `destroy_tokens` (l.962) wipes session,
  autologin and recovery tokens when 2FA is enabled, not API tokens.
- `User#must_change_password?` (l.367): only enforced for Basic auth (see 1.1). API-key
  auth ignores it; a PAT path that mirrors the header/param branch inherits that
  behaviour unless we decide otherwise.
- `User.current` is a thread-local set once per request; `user.oauth_scope=` is the only
  per-request mutable auth state, so a PAT can piggyback on it later for scopes.
- Doorkeeper admin screens require `Setting.rest_api_enabled?`; a PAT UI should follow
  the same gate (`_sidebar.html.erb:21` already hides the API key block when off).
- Hooks: `call_hook(:view_my_account_contextual)`, `:view_my_account`,
  `:view_my_account_preferences` exist for plugins, so adding a new block to the sidebar
  partial is the core way (not a hook).
- `Redmine::Utils.random_hex(n)` is the existing random-secret helper; `bcrypt` is
  already a dependency (used by Doorkeeper for application secrets) if a slow hash is
  wanted, but Doorkeeper itself uses SHA-256 for access tokens, which is the precedent
  for high-entropy tokens.

## 2. What we built

Status: **work breakdown step 1 of 7 done** (spec section 12). Steps 2-7 not started.

### 2.1 User deletion with OAuth tokens and grants (step 1, D-015, D-024, backport of r24916)

- What: `User` gains two associations, `has_many :oauth_access_grants` and
  `has_many :oauth_access_tokens`, both with `:dependent => :delete_all`
  (`app/models/user.rb:105-108`). They are the upstream fix for Redmine #44343
  ("Fix deleting a user who has authorized an OAuth2 application fails with
  ActiveRecord::InvalidForeignKey", trunk r24916), backported to 6.1-stable in
  r24939 and released in 6.1.4. The hunk is byte-identical to `6.1.4`
  (`git diff 6.1.2 6.1.4 -- app/models/user.rb`); the resulting file blob is the
  same as in 6.1.4. Test:
  `test_destroy_should_delete_oauth_access_tokens_and_grants` (`test/unit/user_test.rb:403`),
  ours, kept because it also covers an application-less token, the shape a PAT
  will have (D-010). Upstream's two narrower tests are not copied.
- How: `has_many ... :dependent => :delete_all` registers a `before_destroy`
  callback that issues one SQL `DELETE` per association, without loading rows or
  running their callbacks. It runs inside the destroy transaction, before the
  `users` row is deleted, so the foreign keys
  (`20250611092155_create_doorkeeper_tables.rb:31-35, 62-66`) are satisfied. Same
  mechanism as the neighbouring `email_addresses` and `reactions` associations.
- Why: a pre-existing 6.1.2 bug (section 1.3.1, "Pre-existing gap"): destroying a
  user with any Doorkeeper token or grant raised `ActiveRecord::InvalidForeignKey`.
  Storing PATs in `oauth_access_tokens` (D-010) would expose every PAT user to it.
  Shipped as two commits: the model hunk alone, as a backport maintainers can
  recognise, then our test and this note (D-015). The first implementation used two
  `delete_all` lines inside `remove_references_before_destroy`; the reviewer (R-5,
  recorded as D-024) pointed at the upstream fix, and taking it verbatim means the
  branch converges with 6.1.4 instead of diverging on the same problem. Upstream's
  own two tests (`6.1.4` `test/unit/user_test.rb:239-272`) are not copied (D-024).
  Cascading foreign keys were rejected because Redmine does not use them.
- Verified: the test was run once without the fix and failed with
  `PG::ForeignKeyViolation` on `oauth_access_grants`; with the associations the
  full `user_test.rb` is green (143 runs). Rows are deleted for both
  application-less and application-bound tokens; the `Doorkeeper::Application`
  row is kept (Redmine's schema gives applications no owner column).
- Known limits: `test/system/oauth_provider_test.rb` cannot run in the Docker image
  (no Chrome installed); noted for the reviewer. When the branch is later rebased
  onto or merged with 6.1.4, this commit becomes a no-op rather than a conflict.

For each component, once built: what it is, how it works, why it is shaped that way
(reference `D-NNN`), known limits. Suggested subsections:

- Data model and migration
- Token generation, hashing, and lookup
- Authentication flow and legacy key coexistence
- My account UI
- Settings
- Tests
- Optional pillars (if any)
- Known limits and deferred work

## 3. Workflow and tooling notes

- Tool: Claude Code (Claude Fable 5.1). Each role (planner, critic, implementer,
  reviewer) runs in its own session started by the human (D-018); the definitions in
  `.claude/agents/` are for explicit invocation by the human only. Specs live in
  `ai-workflow/specs/` (D-019).
- Raw transcripts live in `~/.claude/projects/-Users-kbagaiev-Projects-TaxDome/` and
  are copied unedited into `ai-workflow/logs/` before submission.
