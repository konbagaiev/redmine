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

require_relative '../../test_helper'

class Redmine::ApiTest::PersonalAccessTokenAuthenticationTest < Redmine::ApiTest::Base
  def setup
    super
    @user = User.find(2)
    @token = PersonalAccessToken.generate!(:user => @user)
    @plaintext = @token.plaintext_token
  end

  def teardown
    super
    User.current = nil
  end

  def test_should_accept_pat_as_bearer_token
    get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{@plaintext}"}
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_should_accept_pat_in_api_key_header
    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => @plaintext}
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_should_accept_pat_as_key_parameter
    get "/users/current.xml?key=#{@plaintext}"
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_should_accept_pat_as_basic_username_with_any_password
    get '/users/current.xml', :headers => credentials(@plaintext, 'X')
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_should_accept_pat_as_access_token_parameter
    get "/users/current.xml?access_token=#{@plaintext}"
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_should_deny_expired_pat
    @token.update_column(:created_at, 31.days.ago)

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => @plaintext}
    assert_response :unauthorized
    assert response.headers['WWW-Authenticate'].start_with?('Bearer')
    assert_include 'invalid_token', response.headers['WWW-Authenticate']
  end

  def test_should_deny_revoked_pat
    @token.revoke

    get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{@plaintext}"}
    assert_response :unauthorized
    assert response.headers['WWW-Authenticate'].start_with?('Bearer')
  end

  def test_should_deny_pat_of_locked_user
    locked = User.find(5)
    assert locked.locked?
    token = PersonalAccessToken.generate!(:user => locked)

    get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{token.plaintext_token}"}
    assert_response :unauthorized
  end

  def test_should_deny_unknown_token_on_every_transport
    unknown = 'rmpat_unknownunknownunknownunknownunknownunk'
    [
      {'HTTP_AUTHORIZATION' => "Bearer #{unknown}"},
      {'X-Redmine-API-Key' => unknown},
      credentials(unknown, 'X')
    ].each do |headers|
      get '/users/current.xml', :headers => headers
      assert_response :unauthorized
      assert_equal 'Basic realm="Redmine API"', response.headers['WWW-Authenticate']
    end
    get "/users/current.xml?key=#{unknown}"
    assert_response :unauthorized
    get "/users/current.xml?access_token=#{unknown}"
    assert_response :unauthorized
  end

  def test_legacy_api_key_should_still_work_on_every_transport
    key = Token.create!(:user => @user, :action => 'api').value

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => key}
    assert_response :ok
    get "/users/current.xml?key=#{key}"
    assert_response :ok
    get '/users/current.xml', :headers => credentials(key, 'X')
    assert_response :ok
    assert_select 'user login', :text => 'jsmith'
  end

  def test_full_access_pat_should_keep_admin_rights
    admin_token = PersonalAccessToken.generate!(:user => User.find(1))

    get '/users.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{admin_token.plaintext_token}"}
    assert_response :ok

    # api_key is hidden from users authorized via OAuth scopes; a full-access
    # PAT is not scoped, so it is shown as with the legacy key
    get '/users/current.json', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{@plaintext}"}
    assert_response :ok
    assert_kind_of String, ActiveSupport::JSON.decode(response.body)['user']['api_key']
  end

  def test_scoped_application_token_should_not_get_admin_rights
    application = Doorkeeper::Application.create!(
      :name => 'Test app', :redirect_uri => 'https://example.com/callback', :scopes => 'view_issues'
    )
    token = Doorkeeper::AccessToken.create!(
      :resource_owner_id => 1, :application => application, :scopes => 'view_issues', :expires_in => 3600
    )

    get '/users.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{token.plaintext_token}"}
    assert_response :forbidden
  end

  def test_pat_should_update_last_used_at
    assert_nil @token.last_used_at

    get '/users/current.xml', :headers => {'X-Redmine-API-Key' => @plaintext}
    assert_response :ok
    assert_not_nil @token.reload.last_used_at
  end

  def test_pat_should_be_refused_when_rest_api_disabled
    with_settings :rest_api_enabled => '0' do
      get '/users/current.xml', :headers => {'HTTP_AUTHORIZATION' => "Bearer #{@plaintext}"}
      assert_response :forbidden
    end
  end
end
