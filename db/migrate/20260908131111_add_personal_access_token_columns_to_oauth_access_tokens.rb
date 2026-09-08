# frozen_string_literal: true

class AddPersonalAccessTokenColumnsToOauthAccessTokens < ActiveRecord::Migration[7.2]
  def change
    change_table :oauth_access_tokens, bulk: true do |t|
      t.string :name, limit: 255
      t.datetime :last_used_at
      t.string :token_suffix, limit: 4
    end
  end
end
