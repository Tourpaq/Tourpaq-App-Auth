require "test_helper"
require Rails.root.join("db/migrate/20261104100001_add_channels_and_exchanged_tokens")

# Web and MCP channels (SPECS.md §25): the apps whose MCP servers move behind the gateway get the MCP channel, with a
# copy of every grant, so nobody gains or loses anything on the day it ships.
class AddChannelsTest < ActiveSupport::TestCase
  def migrate = ActiveRecord::Migration.suppress_messages { AddChannelsAndExchangedTokens.new.open_mcp_channels }

  test "kpi gets the MCP channel and a copy of its grants; other apps keep the web only" do
    Grant.create!(app: apps(:kpi), subject: users(:alice), app_role: nil) # a direct no access is copied too
    migrate
    kpi = apps(:kpi).reload
    assert_equal %w[web mcp], kpi.channels
    assert_equal %w[web], apps(:irm).reload.channels
    web = kpi.grants.web.map { [ _1.subject, _1.app_role ] }
    assert_equal web.sort_by(&:inspect), kpi.grants.mcp.map { [ _1.subject, _1.app_role ] }.sort_by(&:inspect)
    assert_equal "admin, from DK Tech", EffectiveRole.for(users(:mwi), kpi, channel: "mcp").to_s
    assert_equal "no access (direct)", EffectiveRole.for(users(:alice), kpi, channel: "mcp").to_s
    event = AuditEvent.where(action: "app.channels_changed").last
    assert_equal [ kpi.id, 2, "system" ], [ event.subject_id, event.data["grants_copied_to_mcp"], event.channel ]

    assert_no_difference(-> { Grant.count }) { migrate }
  end
end
