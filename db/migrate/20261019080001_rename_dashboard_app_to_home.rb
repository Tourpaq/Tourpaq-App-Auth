# The Dashboard became Home (SPECS.md §24.1): its app's slug "dashboard" becomes "home", so its client is home-web,
# its claims home_roles / home_permissions and its new tokens tpa_home_. A slug is otherwise never changed
# (App#slug is read-only), which is why this is a migration: it runs before the seeds, which would otherwise create a
# second app "home" next to the old one.
#
# Only a database that has "dashboard" and no "home" is changed; a fresh one has neither (the seeds create "home").
# Kept: the app's id, roles, grants, catalogue, clients and tokens. Existing tpa_dashboard_ tokens still work: a token
# is found by its digest, not its prefix. The role claim follows the slug unless an admin set another one; the name
# "Dashboard" becomes "Home". Recorded as app.renamed. Plain SQL through bare models: no app code, no callbacks.
class RenameDashboardAppToHome < ActiveRecord::Migration[8.1]
  class MigrationApp < ActiveRecord::Base
    self.table_name = "apps"
  end

  class MigrationAuditEvent < ActiveRecord::Base
    self.table_name = "audit_events"
  end

  def up = rename("dashboard", "home", "Dashboard", "Home")

  def down = rename("home", "dashboard", "Home", "Dashboard")

  private

  def rename(from, to, from_name, to_name)
    app = MigrationApp.find_by(slug: from)
    return if app.nil? || MigrationApp.exists?(slug: to)

    before = { "slug" => app.slug, "name" => app.name, "role_claim" => app.role_claim }
    changes = { slug: to }
    changes[:role_claim] = "#{to}_roles" if app.role_claim.blank? || app.role_claim == "#{from}_roles"
    changes[:name] = to_name if app.name == from_name
    app.update_columns(changes.merge(updated_at: Time.current))
    after = { "slug" => app.slug, "name" => app.name, "role_claim" => app.role_claim }
    MigrationAuditEvent.create!(action: "app.renamed", subject_type: "App", subject_id: app.id, app_id: app.id, channel: "system",
                                data: { "before" => before, "after" => after, "via" => "migration" }, created_at: Time.current)
    say "App #{from} is now #{to} (#{after.inspect})"
  end
end
