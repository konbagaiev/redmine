# Redmine code and test conventions (as found in 6.1.2)

Canonical reference for the implementer and the reviewer. Everything here was read
from the 6.1.2 tree or the official wiki on 2026-09-07; file pointers are given so it
can be re-verified. Where Redmine has no written rule, the convention is "do what the
surrounding code does", and the pointers show what that is.

## Sources

- `CONTRIBUTING.md`: development happens on redmine.org, not GitHub. Patches must
  include tests and all existing tests must pass.
- Wiki "Coding Standards" (redmine.org/projects/redmine/wiki/Coding_Standards):
  "Make sure any new code is tested, especially in the Controllers and Models. Code
  without tests may (and probably will) be rejected on that reason alone." Prefer
  `blank?`/`present?` over `empty?`/`nil?` in views. Document methods as needed and
  explain any complex code. Otherwise follow the Rails contributing conventions.
- `.rubocop.yml` + `.rubocop_todo.yml`: enforced in CI (`.github/workflows/linters.yml`
  runs `bundle exec rubocop --parallel`). Also `bundle audit` and stylelint on CSS.
- `.github/workflows/tests.yml`: the suite runs on Ruby 3.2/3.3/3.4 against
  PostgreSQL, MySQL and SQLite. Anything we write must be portable across all three.
- `doc/RUNNING_TESTS`, `lib/tasks/testing.rake`.

## Ruby source files

- **Every Ruby file starts with** `# frozen_string_literal: true`, a blank line, then
  the GPL header exactly as in `app/models/token.rb:1-18`. Migrations are the
  exception: `# frozen_string_literal: true` only (see `db/migrate/20250611092227_enable_pkce.rb`).
- **Hash syntax:** Redmine overwhelmingly uses the rocket style `:key => value`
  (about 2300 occurrences in `app/` versus a handful of `key: value`). Use rockets in
  app code and tests to match neighbors. Migrations and newer files use `key: value`;
  match the file you are in.
- **Style is RuboCop-enforced** with Redmine's own exceptions: metrics cops are
  disabled (`Metrics: Enabled: false`), spacing inside braces is free
  (`Layout/SpaceInsideBlockBraces`, `SpaceInsideHashLiteralBraces` disabled), line
  length has allowances for test names. Do not fight `.rubocop_todo.yml` in files we
  touch; do not add new offenses. Run before every commit:
  `docker compose exec app bundle exec rubocop <changed files>`.
- Target Ruby 3.2 (`TargetRubyVersion: 3.2`): no syntax newer than 3.2.
- Naming: models singular CamelCase in `app/models/`, controllers plural
  `XxxController` in `app/controllers/`, tests mirror the path under `test/`.

## Models

- Inherit from `ApplicationRecord`. Look at `app/models/token.rb` for the size and
  shape of a small model.
- **Mass assignment goes through `safe_attributes`**, Redmine's own mechanism, not
  strong parameters (`app/models/user.rb:819-845`; module in
  `lib/redmine/safe_attributes.rb`). Controllers assign with
  `record.safe_attributes = params[:record]`.
- Access control is `User#allowed_to?` and `Redmine::AccessControl`
  (`lib/redmine/access_control.rb`), not custom checks.
- `User.current` is the request-scoped current user; it is set by the controller.
- Validations use ActiveRecord; error messages come from i18n keys.

## Controllers

- Inherit from `ApplicationController`. Auth filters are declarative:
  `before_action :require_login` (`app/controllers/my_controller.rb:22`),
  `before_action :require_admin` (`app/controllers/settings_controller.rb:27`),
  `require_sudo_mode :action_a, :action_b` (`my_controller.rb:28-29`) for sensitive
  actions. `accept_api_auth :index, :show` declares which actions accept API keys.
- Success flows set `flash[:notice] = l(:notice_...)` and `redirect_to`. Failure
  re-renders the form. See `my_controller.rb:50-75`.
- Routes are explicit in `config/routes.rb` (`my/*` block at line 92). Use `:as` to
  name routes so views can use `xxx_path` helpers; never hardcode URLs in views.
- API responses use `respond_to` with `format.api` and the `.api.rsb` builder views
  (`app/views/my/account.api.rsb`).

## Views (ERB)

- Plain ERB, no other templating. Every user-visible string is `l(:key)` from
  `config/locales/en.yml`. Never a literal English string in a view.
- List pages follow `app/views/auth_sources/index.html.erb`: a `div.contextual` with
  the add link, `<%= title l(:label_xxx_plural) %>`, `<table class="list">` with
  `thead`/`tbody`, rows with `id="record-<id>"`, a `td.buttons` cell using
  `delete_link` (`app/helpers/application_helper.rb:1600`) and `sprite_icon`
  (`app/helpers/icons_helper.rb:36`).
- Sidebars use `content_for :sidebar` (`app/views/my/account.html.erb:75`); page
  titles use `html_title` (line 79). `app/views/my/_sidebar.html.erb` is a partial
  (leading underscore).
- Forms use `labelled_form_for` / `form_tag` with `f.text_field` etc.; look at
  `app/views/my/password.html.erb` for a small form.
- New CSS goes in `app/assets/stylesheets/application.css` and must pass stylelint
  (`.stylelintrc`). Prefer reusing existing classes.
- JavaScript: Stimulus controllers exist (`data-controller="api-key-copy"` in
  `_sidebar.html.erb:23`), plus jQuery. Only add JS if the spec needs it.

## i18n

- Add keys only to `config/locales/en.yml`. Do not touch the other 49 locale files;
  `rake locales:update` propagates English keys to them and maintainers do that.
- Key prefixes: `label_` (nouns, page titles), `field_` (attribute names, used by
  ActiveRecord error messages via `activerecord` mapping too), `button_` (actions),
  `text_` (sentences, help text), `notice_` (flash success), `error_` (flash/validation
  failures), `setting_` (admin settings labels). Plurals are `label_xxx_plural`.
- Run `docker compose exec app bin/rails locales:check_interpolation` if a key uses
  `%{placeholders}`.

## Settings

- Declared in `config/settings.yml` with a default; accessed as `Setting.xxx` /
  `Setting.xxx?`; rendered in admin tabs under `app/views/settings/_*.html.erb` via
  `setting_check_box`, `setting_text_field` (`app/helpers/settings_helper.rb:97-110`).
  See `app/views/settings/_api.html.erb` for the API tab.

## Migrations

- File name `YYYYMMDDHHMMSS_verb_noun.rb`, class `ActiveRecord::Migration[7.2]`,
  `def change` with reversible operations (`db/migrate/20250611092155_create_doorkeeper_tables.rb`,
  `..._enable_pkce.rb`). No GPL header.
- `db/schema.rb` is gitignored; it is never committed. Structure is expressed only by
  migrations, so they must be complete (indexes, null constraints, foreign keys where
  Redmine uses them; note that Redmine mostly does not use DB-level foreign keys).
- Must run on PostgreSQL, MySQL and SQLite: no database-specific SQL or types.

## Tests (minitest, `test/`)

- Layout: `test/unit/<model>_test.rb` (class `XxxTest < ActiveSupport::TestCase`),
  `test/functional/<controller>_test.rb` (`XxxControllerTest < Redmine::ControllerTest`,
  `test/test_helper.rb:353`), `test/integration/...` (`Redmine::IntegrationTest`,
  line 406), `test/integration/api_test/<name>_test.rb`
  (`Redmine::ApiTest::XxxTest < Redmine::ApiTest::Base`, line 437). `test/system/`
  exists but is browser-based; not needed for this slice.
- Every test file starts with the GPL header, then `require_relative '../test_helper'`
  (depth-adjusted), then the class.
- **Test names are `def test_should_do_something`** (289 files) rather than the
  `test "..." do` form (47 files). Use `def test_...`, descriptive, snake_case.
- Fixtures: `fixtures :all` is loaded globally (`test_helper.rb:59`), so
  `test/fixtures/*.yml` are always available. Known users: id 1 = admin, id 2 =
  jsmith (a regular user). `User.find(2)`, `User.find(1)` appear everywhere. A new
  table gets a fixture file `test/fixtures/<table>.yml` only if tests need seeded
  rows; otherwise create records in the test (`User.generate!`, `Token.create!`).
- Functional tests log in with `@request.session[:user_id] = 2` in `setup`
  (`test/functional/my_controller_test.rb:23`), call `get :action`, `post :action,
  :params => {...}`, and assert with `assert_response`, `assert_redirected_to`,
  `assert_select 'css', 'text'`, `assert_select_error`.
- API tests use `credentials(user_login_or_key, password)` for HTTP Basic headers
  (`test_helper.rb:428`) and `Redmine::ApiTest::Base` which enables the REST API for
  the duration of the test. Template: `test/integration/api_test/authentication_test.rb`.
- Helpers to reuse: `with_settings(:key => value) { ... }` (`test_helper.rb:97`),
  `with_current_user(user) { ... }` (line 115), `assert_difference 'Model.count'`,
  `assert_no_difference`, `assert_save`, `assert_include`.
- `setup` often resets `User.current = nil`; API tests do so in `teardown`.
- Cover both the success path and every failure path (unauthorized, forbidden,
  expired, invalid). Auth code is the area where maintainers demand it most.
- Run: `docker compose exec app bin/rails test test/unit/xxx_test.rb`, a single test
  with `-n test_name`, the touched areas together, and `bin/rails test` for the full
  suite before the MR. `bin/rails test:autoload` is part of CI too.

## Commits

Wiki format, which we follow for the MR's commit messages:

```
Short summary, 72 chars max, referencing the ticket (#43881)

Optional longer description, 72-char lines.
```

Small, single-purpose commits; each leaves the tests green.
