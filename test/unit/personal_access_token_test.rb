# frozen_string_literal: true

# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require_relative '../test_helper'

class PersonalAccessTokenTest < ActiveSupport::TestCase
  def setup
    User.current = nil
  end

  def test_should_generate_prefixed_token_and_store_sha256_hash
    token = PersonalAccessToken.generate!
    plaintext = token.plaintext_token

    assert plaintext.start_with?(PersonalAccessToken::TOKEN_PREFIX)
    assert_equal 49, plaintext.length
    assert_equal Digest::SHA256.hexdigest(plaintext), token.token
    assert_equal plaintext.last(4), token.token_suffix
    assert_nil token.application_id
  end

  def test_should_be_found_by_plaintext_token
    token = PersonalAccessToken.generate!

    assert_equal token.id, Doorkeeper::AccessToken.by_token(token.plaintext_token).id
    assert_nil Doorkeeper::AccessToken.by_token('rmpat_unknown')
  end

  def test_should_set_expires_in_from_lifetime_days
    token = PersonalAccessToken.generate!(:lifetime_days => 30)

    assert_equal 30.days.to_i, token.expires_in
    assert_equal token.created_at + 30.days, token.expires_at
  end

  def test_should_accept_lifetime_as_string_from_form
    token = PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => '90')

    assert token.save
    assert_equal 90, token.lifetime_days
    assert_equal 90.days.to_i, token.expires_in
  end

  def test_should_require_name
    token = PersonalAccessToken.new(:user => User.find(2), :lifetime_days => 30)

    assert !token.save
    assert_include "Name cannot be blank", token.errors.full_messages
  end

  def test_should_require_lifetime
    token = PersonalAccessToken.new(:user => User.find(2), :name => 'cron')

    assert !token.save
    assert_equal [:lifetime_days], token.errors.attribute_names
    assert_equal ["is not included in the list"], token.errors[:lifetime_days]
    assert_nil token.expires_in
  end

  def test_should_reject_unknown_lifetime
    [45, 0, -1, 'abc', '30abc', ''].each do |value|
      token = PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => value)

      assert !token.save, "#{value.inspect} was accepted"
      assert_equal [:lifetime_days], token.errors.attribute_names
      assert_equal ["is not included in the list"], token.errors[:lifetime_days]
    end
  end

  def test_should_reject_lifetime_above_setting_cap
    with_settings :personal_access_token_max_lifetime => 30 do
      token = PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => 90)

      assert !token.save
      assert_equal [:lifetime_days], token.errors.attribute_names
      assert_equal ["is not included in the list"], token.errors[:lifetime_days]
      assert PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => 30).save
    end
  end

  def test_allowed_lifetimes_should_respect_cap
    with_settings :personal_access_token_max_lifetime => 0 do
      assert_equal [7, 30, 60, 90, 180, 365], PersonalAccessToken.allowed_lifetimes
    end
    with_settings :personal_access_token_max_lifetime => 90 do
      assert_equal [7, 30, 60, 90], PersonalAccessToken.allowed_lifetimes
    end
    with_settings :personal_access_token_max_lifetime => 3 do
      assert_equal [], PersonalAccessToken.allowed_lifetimes
    end
  end

  def test_name_should_be_unique_among_active_tokens_of_user
    PersonalAccessToken.generate!(:user => User.find(2), :name => 'Cron')

    duplicate = PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => 30)
    assert !duplicate.save
    assert_include "Name has already been taken", duplicate.errors.full_messages

    assert PersonalAccessToken.new(:user => User.find(3), :name => 'Cron', :lifetime_days => 30).save

    PersonalAccessToken.find_by(:name => 'Cron', :resource_owner_id => 2).revoke
    assert duplicate.save
  end

  def test_should_not_accept_application
    application = Doorkeeper::Application.create!(
      :name => 'Test app', :redirect_uri => 'https://example.com/callback', :scopes => ''
    )
    token = PersonalAccessToken.new(:user => User.find(2), :name => 'cron', :lifetime_days => 30,
                                    :application => application)

    assert !token.save
    assert_include "Application must be blank", token.errors.full_messages
  end

  def test_should_have_no_refresh_token_and_blank_scopes
    token = PersonalAccessToken.generate!

    assert_nil token.refresh_token
    assert token.scopes.all.empty?
    assert_nil token.reload.scopes_string
  end

  def test_should_be_expired_after_lifetime
    token = PersonalAccessToken.generate!(:lifetime_days => 7)
    assert token.accessible?

    token.update_column(:created_at, 8.days.ago)
    token.reload
    assert token.expired?
    assert !token.accessible?
  end

  def test_revoke_should_set_revoked_at
    token = PersonalAccessToken.generate!

    token.revoke
    token.reload
    assert_not_nil token.revoked_at
    assert token.revoked?
    assert !token.accessible?
    assert_equal [], User.find(2).personal_access_tokens.not_revoked.ids
  end

  def test_track_use_should_write_last_used_at_and_throttle
    token = PersonalAccessToken.generate!
    assert_nil token.last_used_at

    # Doorkeeper.authenticate returns the base class, not ours
    PersonalAccessToken.track_use(Doorkeeper::AccessToken.find(token.id))
    first_use = token.reload.last_used_at
    assert_not_nil first_use

    token.update_column(:last_used_at, 30.seconds.ago)
    recent = token.reload.last_used_at
    PersonalAccessToken.track_use(Doorkeeper::AccessToken.find(token.id))
    assert_equal recent, token.reload.last_used_at

    token.update_column(:last_used_at, 2.minutes.ago)
    PersonalAccessToken.track_use(Doorkeeper::AccessToken.find(token.id))
    assert token.reload.last_used_at > 1.minute.ago
  end

  def test_track_use_should_ignore_application_tokens
    application = Doorkeeper::Application.create!(
      :name => 'Test app', :redirect_uri => 'https://example.com/callback', :scopes => ''
    )
    token = Doorkeeper::AccessToken.create!(
      :resource_owner_id => 2, :application => application, :expires_in => 3600
    )

    PersonalAccessToken.track_use(token)
    assert_nil token.reload.last_used_at
  end

  def test_full_access_should_be_true_only_for_app_less_token_with_blank_scopes
    application = Doorkeeper::Application.create!(
      :name => 'Test app', :redirect_uri => 'https://example.com/callback', :scopes => 'view_issues'
    )

    assert PersonalAccessToken.full_access?(PersonalAccessToken.generate!)
    assert !PersonalAccessToken.full_access?(
      Doorkeeper::AccessToken.create!(:resource_owner_id => 2, :application => application,
                                      :scopes => 'view_issues', :expires_in => 3600)
    )
    assert !PersonalAccessToken.full_access?(
      Doorkeeper::AccessToken.create!(:resource_owner_id => 2, :application => application,
                                      :scopes => '', :expires_in => 3600)
    )
    assert !PersonalAccessToken.full_access?(
      Doorkeeper::AccessToken.create!(:resource_owner_id => 2, :application_id => nil,
                                      :scopes => 'view_issues', :expires_in => 3600)
    )
    # no application, no scopes, but no expiry either: not created by this model
    assert !PersonalAccessToken.full_access?(
      Doorkeeper::AccessToken.create!(:resource_owner_id => 2)
    )
  end
end
