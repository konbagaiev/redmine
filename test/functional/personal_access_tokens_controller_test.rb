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

class PersonalAccessTokensControllerTest < Redmine::ControllerTest
  def setup
    User.current = nil
    @request.session[:user_id] = 2
    Setting.rest_api_enabled = '1'
  end

  def teardown
    Setting.rest_api_enabled = '0'
  end

  def test_index_should_list_active_and_expired_but_not_revoked_tokens
    active = PersonalAccessToken.generate!(:name => 'Active one')
    expired = PersonalAccessToken.generate!(:name => 'Expired one', :lifetime_days => 7)
    expired.update_column(:created_at, 8.days.ago)
    revoked = PersonalAccessToken.generate!(:name => 'Revoked one')
    revoked.revoke

    get :index
    assert_response :success
    assert_select 'table.personal-access-tokens tbody tr', 2
    assert_select "tr#personal-access-token-#{active.id}" do
      assert_select 'td.name', :text => 'Active one'
      assert_select 'td code', :text => "…#{active.token_suffix}"
      assert_select 'td.status', :text => 'Active'
      assert_select 'a[href=?][data-method=delete]', "/my/api_tokens/#{active.id}"
    end
    assert_select "tr#personal-access-token-#{expired.id} td.status", :text => 'Expired'
    assert_select "tr#personal-access-token-#{revoked.id}", 0
    assert_select 'pre#new-personal-access-token', 0
  end

  def test_index_without_tokens_should_show_specific_empty_message
    get :index
    assert_response :success
    assert_select 'table.personal-access-tokens', 0
    assert_select 'p.nodata', :text => /no personal access tokens/
  end

  def test_index_should_show_last_used
    token = PersonalAccessToken.generate!
    get :index
    assert_select "tr#personal-access-token-#{token.id} td", :text => 'Never'

    token.update_column(:last_used_at, 3.hours.ago)
    get :index
    assert_select "tr#personal-access-token-#{token.id} td", :text => 'used about 3 hours ago'
  end

  def test_index_should_render_legacy_api_key_sidebar
    get :index
    assert_select '#sidebar pre#api-access-key'
  end

  def test_index_should_require_login
    @request.session[:user_id] = nil
    get :index
    assert_redirected_to '/login?back_url=http%3A%2F%2Ftest.host%2Fmy%2Fapi_tokens'
  end

  def test_index_should_deny_when_rest_api_disabled
    Setting.rest_api_enabled = '0'
    get :index
    assert_response :forbidden
  end

  def test_index_should_show_create_form_with_allowed_lifetimes
    get :index
    assert_response :success
    assert_select 'form[action="/my/api_tokens"]' do
      assert_select 'input[name=?]', 'personal_access_token[name]'
      assert_select 'label[for=personal_access_token_name] span.required'
      assert_select 'label[for=personal_access_token_lifetime_days]', :text => /Expires in/
      assert_select 'select[name=?]', 'personal_access_token[lifetime_days]' do
        assert_select 'option', 6
        assert_select 'option[value="30"][selected=selected]', :text => '30 days'
      end
    end
  end

  def test_index_should_show_create_form_with_cap
    with_settings :personal_access_token_max_lifetime => 30 do
      get :index
      assert_select 'select[name=?]', 'personal_access_token[lifetime_days]' do
        assert_select 'option', 2
        assert_select 'option[value="7"]'
        assert_select 'option[value="30"][selected=selected]'
      end
    end
    with_settings :personal_access_token_max_lifetime => 7 do
      get :index
      assert_select 'select[name=?]', 'personal_access_token[lifetime_days]' do
        assert_select 'option', 1
        assert_select 'option[value="7"][selected=selected]'
      end
    end
  end

  def test_index_should_show_create_form_without_form_when_no_lifetime_allowed
    with_settings :personal_access_token_max_lifetime => 3 do
      get :index
      assert_response :success
      assert_select 'form[action="/my/api_tokens"]', 0
      assert_select 'p.warning', :text => 'No token lifetime is allowed by the administrator.'
    end
  end

  def test_create_should_create_token_and_show_plaintext_once
    assert_difference 'PersonalAccessToken.count' do
      post :create, :params => {:personal_access_token => {:name => 'CI job', :lifetime_days => '60'}}
    end
    assert_redirected_to '/my/api_tokens'
    token = PersonalAccessToken.personal.order(:id).last
    assert_equal 'CI job', token.name
    assert_equal 60.days.to_i, token.expires_in
    assert_equal 2, token.resource_owner_id

    get :index
    assert_response :success
    assert_includes @response.headers['Cache-Control'], 'no-store'
    assert_select 'pre#new-personal-access-token' do |pre|
      plaintext = pre.text.strip
      assert plaintext.start_with?('rmpat_')
      assert_equal token.id, Doorkeeper::AccessToken.by_token(plaintext).id
    end
    assert_select 'div.flash.notice', :text => /Copy it now/

    get :index
    assert_response :success
    assert_select 'pre#new-personal-access-token', 0
    assert_not_includes @response.headers['Cache-Control'].to_s, 'no-store'
  end

  def test_new_token_should_never_be_rendered_as_flash_message
    post :create, :params => {:personal_access_token => {:name => 'CI job', :lifetime_days => '30'}}
    get :index
    assert_response :success
    assert_select '#flash_personal_access_token', 0
    assert_select 'pre#new-personal-access-token', 1

    Setting.rest_api_enabled = '0'
    get :index, :flash => {:personal_access_token => ['rmpat_secretsecretsecretsecretsecretsecretsec']}
    assert_response :forbidden
    assert_select '#flash_personal_access_token', 0
    assert_not_includes @response.body, 'rmpat_secret'
  end

  def test_create_with_invalid_name_should_rerender_form
    assert_no_difference 'PersonalAccessToken.count' do
      post :create, :params => {:personal_access_token => {:name => '', :lifetime_days => '30'}}
    end
    assert_response :success
    assert_select_error /Name cannot be blank/
    assert_select 'select[name=?] option[value="30"][selected=selected]', 'personal_access_token[lifetime_days]'
  end

  def test_create_with_lifetime_above_cap_should_fail
    with_settings :personal_access_token_max_lifetime => 30 do
      assert_no_difference 'PersonalAccessToken.count' do
        post :create, :params => {:personal_access_token => {:name => 'CI job', :lifetime_days => '90'}}
      end
      assert_response :success
      assert_select_error /Expires in is not included in the list/
    end
  end

  def test_create_with_duplicate_name_should_fail
    PersonalAccessToken.generate!(:name => 'CI job')
    assert_no_difference 'PersonalAccessToken.count' do
      post :create, :params => {:personal_access_token => {:name => 'ci JOB', :lifetime_days => '30'}}
    end
    assert_response :success
    assert_select_error /Name has already been taken/
  end

  def test_create_should_ignore_unsafe_attributes
    application = Doorkeeper::Application.create!(
      :name => 'Test app', :redirect_uri => 'https://example.com/callback', :scopes => 'admin'
    )
    post :create, :params => {
      :personal_access_token => {
        :name => 'CI job', :lifetime_days => '30',
        :expires_in => 10.years.to_i, :scopes => 'admin',
        :application_id => application.id, :resource_owner_id => 1
      }
    }
    assert_redirected_to '/my/api_tokens'
    token = PersonalAccessToken.personal.order(:id).last
    assert_equal 30.days.to_i, token.expires_in
    assert token.scopes.all.empty?
    assert_nil token.application_id
    assert_equal 2, token.resource_owner_id
  end

  def test_destroy_should_revoke_token
    token = PersonalAccessToken.generate!
    assert_no_difference 'Doorkeeper::AccessToken.count' do
      delete :destroy, :params => {:id => token.id}
    end
    assert_redirected_to '/my/api_tokens'
    assert_not_nil token.reload.revoked_at
    assert_equal 'Personal access token revoked.', flash[:notice]
  end

  def test_destroy_should_not_revoke_other_users_token
    token = PersonalAccessToken.generate!(:user => User.find(3))
    delete :destroy, :params => {:id => token.id}
    assert_response :not_found
    assert_nil token.reload.revoked_at
  end

  def test_destroy_of_already_revoked_token_should_be_not_found
    token = PersonalAccessToken.generate!
    token.revoke
    delete :destroy, :params => {:id => token.id}
    assert_response :not_found
  end

  def test_destroy_should_deny_when_rest_api_disabled
    token = PersonalAccessToken.generate!
    Setting.rest_api_enabled = '0'
    delete :destroy, :params => {:id => token.id}
    assert_response :forbidden
    assert_nil token.reload.revoked_at
  end
end
