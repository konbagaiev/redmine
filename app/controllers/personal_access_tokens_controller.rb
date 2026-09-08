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

class PersonalAccessTokensController < ApplicationController
  self.main_menu = false

  # Declared first: the one-time plaintext travels in the flash for a single
  # redirect and must be consumed before any later filter can render a page
  # that would print it as a flash message
  before_action :read_new_token_from_flash
  before_action :require_login
  before_action :require_rest_api_enabled
  require_sudo_mode :create, :destroy

  def index
    @tokens = User.current.personal_access_tokens.not_revoked.order(:created_at => :desc).to_a
    @token ||= PersonalAccessToken.new
    no_store if @new_token_value
  end

  def create
    @token = PersonalAccessToken.new(:user => User.current)
    @token.safe_attributes = params[:personal_access_token]
    if @token.save
      flash[:personal_access_token] = [@token.plaintext_token]
      flash[:notice] = l(:notice_personal_access_token_created)
      redirect_to my_api_tokens_path
    else
      index
      render :action => 'index'
    end
  end

  # Revoked tokens are not listed, so they are not found either. The lookup
  # happens after the sudo-mode check, so every DELETE is challenged alike.
  def destroy
    token = User.current.personal_access_tokens.not_revoked.find(params[:id])
    token.revoke
    flash[:notice] = l(:notice_personal_access_token_revoked)
    redirect_to my_api_tokens_path
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  private

  def read_new_token_from_flash
    @new_token_value = Array(flash[:personal_access_token]).first
    flash.delete(:personal_access_token)
  end

  def require_rest_api_enabled
    deny_access unless Setting.rest_api_enabled?
  end
end
