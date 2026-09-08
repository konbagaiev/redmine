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

# A personal access token (PAT) is a Doorkeeper access token that belongs to
# no OAuth application: it is issued by its owner from "My account" and
# presented to the REST API like the legacy API key. Doorkeeper stores the
# SHA-256 of the token and hands out the plaintext once, on creation.
class PersonalAccessToken < Doorkeeper::AccessToken
  include Redmine::SafeAttributes

  TOKEN_PREFIX = 'rmpat_'
  # Allowed lifetimes in days, the same list as the password_max_age setting
  LIFETIMES = [7, 30, 60, 90, 180, 365]

  # Prepends the prefix to Doorkeeper's random token so a PAT is recognisable
  # and can never be mistaken for a legacy API key
  module TokenGenerator
    def self.generate(options={})
      TOKEN_PREFIX + Doorkeeper::OAuth::Helpers::UniqueToken.generate(options)
    end
  end

  belongs_to :user, :foreign_key => 'resource_owner_id', :inverse_of => :personal_access_tokens

  scope :personal, lambda {where(:application_id => nil)}
  scope :not_revoked, lambda {where(:revoked_at => nil)}

  # Virtual attribute fed by the form; turned into expires_in on create
  attr_reader :lifetime_days

  safe_attributes 'name', 'lifetime_days'

  validates :name, :presence => true, :length => {:maximum => 255}
  validates :name, :uniqueness => {:scope => :resource_owner_id,
                                    :conditions => -> { personal.not_revoked },
                                    :case_sensitive => false}
  validates :application_id, :absence => true
  validates :lifetime_days, :inclusion => {:in => ->(token) { PersonalAccessToken.allowed_lifetimes }},
                            :on => :create

  before_validation :set_expiry, :on => :create

  # The form posts a String; the inclusion validation compares Integers.
  # Integer(value, exception: false) returns nil for '', 'abc' or '30abc'.
  def lifetime_days=(value)
    @lifetime_days = Integer(value, exception: false)
  end

  # Lifetimes an owner may choose, capped by the admin setting (0 = no cap)
  def self.allowed_lifetimes
    cap = Setting.personal_access_token_max_lifetime.to_i
    cap > 0 ? LIFETIMES.select {|days| days <= cap} : LIFETIMES
  end

  # Records the use of an application-less token, at most once a minute,
  # without loading or validating the record (as User#update_last_login_on!)
  def self.track_use(access_token)
    return unless access_token.application_id.nil?
    return if access_token.last_used_at && access_token.last_used_at >= 1.minute.ago

    where(:id => access_token.id).update_all(:last_used_at => Time.now)
  end

  # An application-less token with no scopes grants the owner's full rights,
  # exactly like the legacy API key
  def self.full_access?(access_token)
    access_token.application_id.nil? && access_token.scopes.all.empty?
  end

  def token_generator
    TokenGenerator
  end

  private

  def set_expiry
    self.expires_in = lifetime_days.days.to_i if lifetime_days.is_a?(Integer)
  end

  def generate_token
    super
    self.token_suffix = plaintext_token.last(4)
  end
end
