# Ready-made roles for a multiple-roles app (SPECS.md §23.2), so its roles are one click on the app page instead of
# somebody working out permission keys. The sets are defined here per app slug; an app without a definition gets no
# button.
#
#   StarterRoles.for(app)        # [StarterRoles::Role] with the permissions the app's catalogue knows
#   StarterRoles.missing(app)    # those the app does not have yet (by name, without regard to case)
#   StarterRoles.admin_role(app) # the one that gives everything ("*")
#   StarterRoles.create!(app, admin_group: group_or_nil)  # => Result(created:, grant:)
#
# `create!` adds only the missing roles, never changes an existing one, and audits each as app.role_added (with
# via "starter_roles"). With `admin_group` the group is also given the admin role through GrantChange (audited
# there); a refused grant comes back on the result with its errors, the roles stay.
class StarterRoles
  Role = Data.define(:key, :description, :permissions)
  Result = Data.define(:created, :grant)

  # Who administers the apps (the seeds make DK Tech admin in every app that has an admin role).
  ADMIN_GROUP = "DK Tech".freeze

  DEFINITIONS = {
    "dashboard" => [
      Role.new(key: "Admin", description: "Everything, including Administration and the confidential figures",
               permissions: [ AppRole::WILDCARD ]),
      Role.new(key: "Management", description: "Staff, plus Management, release notes and the financial figures",
               permissions: %w[module:dashboard:view module:customers:view module:tasks:view module:management:view
                               module:release_notes:manage management:finance:view]),
      Role.new(key: "Staff", description: "Dashboard, customers and their own tasks",
               permissions: %w[module:dashboard:view module:customers:view module:tasks:view])
    ]
  }.freeze

  # The app's starter roles. Once the app has pushed its catalogue, keys it no longer knows are left out, so a starter
  # role is never born with "unknown permissions".
  def self.for(app)
    roles = DEFINITIONS.fetch(app.slug, [])
    return [] unless app.multiple_roles?
    return roles unless app.catalogue_pushed?

    known = app.catalogue_keys.to_set
    roles.map { |role| role.with(permissions: role.permissions.select { _1 == AppRole::WILDCARD || known.include?(_1) }) }
  end

  def self.missing(app)
    have = app.roles.map { _1.key.downcase }.to_set
    self.for(app).reject { have.include?(_1.key.downcase) }
  end

  def self.admin_role(app) = self.for(app).find { _1.permissions.include?(AppRole::WILDCARD) }

  def self.create!(app, admin_group: nil)
    created = App.transaction do
      missing(app).map do |role|
        app.add_role!(role.key, description: role.description, permissions: role.permissions).tap do |added|
          AuditEvent.record("app.role_added", subject: app, data: { key: added.key, description: added.description,
                                                                   permissions: added.permissions, via: "starter_roles" })
        end
      end
    end
    app.roles.reset
    grant = nil
    if admin_group && (admin = admin_role(app)) && (role = app.role(admin.key))
      grant = GrantChange.add(app: app, subject: admin_group, role: role)
    end
    Result.new(created: created, grant: grant)
  end
end
