# The MCP Gateway's SQL source became three read replicas, one per environment, each its own app (SPECS.md §25.6):
# "staging-sql" becomes "replica-staging" (the seeds add replica-bravo and replica-x), so that whoever had MCP access
# to the staging SQL Server keeps it on the staging replica. A migration, as for dashboard → home: it runs before the
# seeds, which would otherwise create a second app next to the old one.
#
# Only a database that has "staging-sql" and no "replica-staging" is changed; a fresh one has neither. Kept: the app's
# id, roles and grants. The role claim follows the slug unless an admin set another one; the seeded name and
# description follow too. Recorded as app.renamed. Plain SQL through bare models: no app code, no callbacks.
class RenameStagingSqlAppToReplicaStaging < ActiveRecord::Migration[8.1]
  class MigrationApp < ActiveRecord::Base
    self.table_name = "apps"
  end

  class MigrationAuditEvent < ActiveRecord::Base
    self.table_name = "audit_events"
  end

  OLD = { slug: "staging-sql", name: "Staging SQL Server",
          description: "Read-only SQL on the staging databases, through the MCP Gateway." }.freeze
  NEW = { slug: "replica-staging", name: "SQL Replica Staging",
          description: "Read-only SQL on the staging read replica, through the MCP Gateway." }.freeze

  def up = rename(OLD, NEW)

  def down = rename(NEW, OLD)

  private

  def rename(from, to)
    app = MigrationApp.find_by(slug: from[:slug])
    return if app.nil? || MigrationApp.exists?(slug: to[:slug])

    before = { "slug" => app.slug, "name" => app.name, "role_claim" => app.role_claim }
    changes = { slug: to[:slug] }
    old_claim = "#{from[:slug].tr('-', '_')}_role"
    changes[:role_claim] = "#{to[:slug].tr('-', '_')}_role" if app.role_claim.blank? || app.role_claim == old_claim
    changes[:name] = to[:name] if app.name == from[:name]
    changes[:description] = to[:description] if app.description == from[:description]
    app.update_columns(changes.merge(updated_at: Time.current))
    after = { "slug" => app.slug, "name" => app.name, "role_claim" => app.role_claim }
    MigrationAuditEvent.create!(action: "app.renamed", subject_type: "App", subject_id: app.id, app_id: app.id, channel: "system",
                                data: { "before" => before, "after" => after, "via" => "migration" }, created_at: Time.current)
    say "App #{from[:slug]} is now #{to[:slug]} (#{after.inspect})"
  end
end
