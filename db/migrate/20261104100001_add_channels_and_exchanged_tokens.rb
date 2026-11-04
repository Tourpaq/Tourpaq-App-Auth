# Web and MCP access per app (SPECS.md §25): an app is reached on the web channel (sign-in, the ID token, the access
# API, its own personal tokens), on the MCP channel (through the MCP Gateway), or both, and every grant is for one
# channel. A person can so have a role on the web, in MCP, or both, each set on its own.
#
# - apps.web_channel (default on), apps.mcp_channel (default off), apps.gateway (the MCP Gateway app itself);
# - grants.channel ("web" for every existing grant); the unique index gains the channel;
# - the apps whose MCP servers move behind the gateway (logs, kpi, offers-validator) get the MCP channel, and each of
#   their grants is copied to it, so nobody gains or loses anything on the day this ships (they reached those MCP
#   servers with their web role until now). Recorded as app.channels_changed;
# - exchanged_tokens: the short-lived tokens the gateway gets for one app (RFC 8693, §25.5).
#
# Plain SQL through bare models: no app code, no callbacks.
class AddChannelsAndExchangedTokens < ActiveRecord::Migration[8.1]
  MCP_APPS = %w[logs kpi offers-validator].freeze

  class MigrationApp < ActiveRecord::Base
    self.table_name = "apps"
  end

  class MigrationGrant < ActiveRecord::Base
    self.table_name = "grants"
  end

  class MigrationAuditEvent < ActiveRecord::Base
    self.table_name = "audit_events"
  end

  def up
    add_column :apps, :web_channel, :boolean, default: true, null: false
    add_column :apps, :mcp_channel, :boolean, default: false, null: false
    add_column :apps, :gateway, :boolean, default: false, null: false
    add_column :grants, :channel, :string, default: "web", null: false
    remove_index :grants, name: "index_grants_on_app_subject_and_role"
    add_index :grants, %i[app_id subject_type subject_id channel app_role_id], unique: true, name: "index_grants_on_app_subject_channel_and_role"

    create_table :exchanged_tokens do |t|
      t.references :personal_token, null: false, foreign_key: true, index: true # the MCP Gateway token it came from
      t.references :app, null: false, foreign_key: true                         # the audience
      t.references :client, null: false, foreign_key: true                      # the gateway's client (act)
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.string :token_hint, null: false
      t.string :scope, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
      t.index :token_digest, unique: true
      t.index :expires_at
    end

    open_mcp_channels
  end

  # The data step on its own (test/db/add_channels_test.rb): idempotent.
  def open_mcp_channels
    MigrationApp.reset_column_information
    MigrationGrant.reset_column_information
    MigrationApp.where(slug: MCP_APPS).find_each do |app|
      app.update_columns(mcp_channel: true, updated_at: Time.current)
      copied = 0
      MigrationGrant.where(app_id: app.id, channel: "web").find_each do |grant|
        next if MigrationGrant.exists?(app_id: app.id, subject_type: grant.subject_type, subject_id: grant.subject_id,
                                       channel: "mcp", app_role_id: grant.app_role_id)
        MigrationGrant.create!(app_id: app.id, subject_type: grant.subject_type, subject_id: grant.subject_id,
                               app_role_id: grant.app_role_id, channel: "mcp", created_at: Time.current, updated_at: Time.current)
        copied += 1
      end
      MigrationAuditEvent.create!(action: "app.channels_changed", subject_type: "App", subject_id: app.id, app_id: app.id,
                                  channel: "system", created_at: Time.current,
                                  data: { "web" => true, "mcp" => true, "grants_copied_to_mcp" => copied, "via" => "migration" })
      say "#{app.slug}: MCP channel on, #{copied} grants copied to it"
    end
  end

  def down
    drop_table :exchanged_tokens
    execute "DELETE FROM grants WHERE channel <> 'web'"
    remove_index :grants, name: "index_grants_on_app_subject_channel_and_role"
    add_index :grants, %i[app_id subject_type subject_id app_role_id], unique: true, name: "index_grants_on_app_subject_and_role"
    remove_column :grants, :channel
    remove_column :apps, :gateway
    remove_column :apps, :mcp_channel
    remove_column :apps, :web_channel
  end
end
