require "test_helper"
require Rails.root.join("db/migrate/20261105090001_rename_staging_sql_app_to_replica_staging")

# The staging SQL source became the staging read replica (SPECS.md §25.6): the migration renames an existing
# "staging-sql" app before the seeds run, so its MCP grants stay.
class RenameStagingSqlAppTest < ActiveSupport::TestCase
  def migrate(direction = :up)
    ActiveRecord::Migration.suppress_messages { RenameStagingSqlAppToReplicaStaging.new.migrate(direction) }
  end

  def create_staging_sql
    App.create!(slug: "staging-sql", name: "Staging SQL Server", description: "Read-only SQL on the staging databases, through the MCP Gateway.",
                web_channel: false, mcp_channel: true, roles: [ AppRole.new(key: "viewer", position: 1), AppRole.new(key: "admin", position: 2) ])
  end

  test "staging-sql becomes replica-staging: slug, role claim, name and description; roles and MCP grants stay" do
    app = create_staging_sql
    GrantChange.set(app: app, subject: users(:alice), role: app.role("viewer"), channel: "mcp")

    migrate
    app.reload
    assert_equal [ "replica-staging", "replica_staging_role", "SQL Replica Staging" ], [ app.slug, app.role_claim, app.name ]
    assert_match "staging read replica", app.description
    assert_equal %w[viewer admin], app.role_keys
    assert_equal "viewer", EffectiveRole.for(users(:alice), app, channel: "mcp").role_key
    event = AuditEvent.where(action: "app.renamed").last
    assert_equal [ app, "staging-sql", "replica-staging" ], [ event.subject, event.data.dig("before", "slug"), event.data.dig("after", "slug") ]

    migrate(:down)
    assert_equal [ "staging-sql", "staging_sql_role", "Staging SQL Server" ], app.reload.values_at(:slug, :role_claim, :name)
  end

  test "a name an admin chose is kept" do
    app = create_staging_sql
    app.update!(name: "Staging DB")
    migrate
    assert_equal [ "replica-staging", "Staging DB" ], app.reload.values_at(:slug, :name)
  end

  test "nothing happens without staging-sql, or when replica-staging exists already" do
    assert_no_difference -> { AuditEvent.count } do
      migrate
    end
    create_staging_sql
    App.create!(slug: "replica-staging", name: "Replica", web_channel: false, mcp_channel: true, roles: [ AppRole.new(key: "viewer", position: 1) ])
    migrate
    assert App.exists?(slug: "staging-sql")
  end
end
