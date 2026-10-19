require "test_helper"
require Rails.root.join("db/migrate/20261019080001_rename_dashboard_app_to_home")

# The Dashboard became Home (SPECS.md §24.1): the migration renames an existing "dashboard" app before the seeds run.
class RenameDashboardAppToHomeTest < ActiveSupport::TestCase
  def migrate(direction = :up)
    ActiveRecord::Migration.suppress_messages { RenameDashboardAppToHome.new.migrate(direction) }
  end

  test "a dashboard app becomes home: slug, the default role claim and the name; roles, grants and clients stay" do
    app = create_dashboard_app
    App.where(id: app.id).update_all(slug: "dashboard", role_claim: "dashboard_roles", name: "Dashboard") # slug is read-only in the model
    grant_dashboard(users(:alice), "Support", app: app)

    migrate
    app.reload
    assert_equal [ "home", "home_roles", "home_permissions", "Home" ], [ app.slug, app.role_claim, app.permissions_claim, app.name ]
    assert_equal [ "Administrators", "Finance readers", "Support" ], app.role_keys.sort
    assert_equal [ "Support" ], EffectiveRole.for(users(:alice), app).role_keys
    assert_equal app, Client.find_by!(client_id: "home-web").app
    event = AuditEvent.where(action: "app.renamed").last
    assert_equal [ app, "dashboard", "home", "system" ], [ event.subject, event.data.dig("before", "slug"), event.data.dig("after", "slug"), event.channel ]

    migrate(:down)
    assert_equal [ "dashboard", "dashboard_roles", "Dashboard" ], app.reload.values_at(:slug, :role_claim, :name)
  end

  test "a role claim or name an admin chose is kept" do
    app = create_dashboard_app
    App.where(id: app.id).update_all(slug: "dashboard", role_claim: "home_roles", name: "Tourpaq Home")
    migrate
    assert_equal [ "home", "home_roles", "Tourpaq Home" ], app.reload.values_at(:slug, :role_claim, :name)
  end

  test "nothing happens without a dashboard app, or when home exists already" do
    assert_no_difference -> { AuditEvent.count } do
      migrate
    end

    create_dashboard_app # slug "home"
    App.create!(slug: "dashboard", name: "Old", multiple_roles: true)
    migrate
    assert App.exists?(slug: "dashboard")
    assert_equal 0, AuditEvent.where(action: "app.renamed").count
  end
end
