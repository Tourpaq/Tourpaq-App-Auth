# The per-app last-administrator guard (SPECS.md §23.2): an app with permission-carrying roles may name an
# admin permission (the Dashboard's admin:access:manage). A change that would leave no active user holding it,
# through "*" or the key itself, is refused. This is the Dashboard's sole_administrator? guard, moved here.
#
#   AppAdminGuard.protect(apps) { grant.destroy! }   # runs the block in a transaction (savepoint); when one of
#                                                    # the apps had a holder before and has none after, it rolls
#                                                    # back and raises AppAdminGuard::LastAdmin
#   AppAdminGuard.holders(app)                       # active users holding the admin permission
#   AppAdminGuard.apps_held_by(user)                 # guarded apps in which the user holds it
#
# Every change that can take a permission away goes through it: removing or replacing a grant, a group
# membership or a whole group, editing a role's permissions, disabling a user. An app nobody administers yet
# (before the Dashboard's import, §23.5) is not guarded: there is nobody to protect. Pushing a catalogue never
# counts, since unknown keys are still sent to the app (§23.2).
module AppAdminGuard
  class LastAdmin < StandardError
    attr_reader :app

    def initialize(app)
      @app = app
      super("#{app.name} needs at least one active user with #{app.admin_permission}: this change would leave nobody " \
            "with it. Give it to somebody else first.")
    end
  end

  module_function

  def guarded?(app) = app.multiple_roles? && app.admin_permission.present? && app.active?

  def holders(app)
    return [] unless guarded?(app)
    EffectiveRole.members_of(app).select { _1.permission?(app.admin_permission) }.map(&:user)
  end

  def apps_held_by(user)
    App.active.where(multiple_roles: true).where.not(admin_permission: nil).select do |app|
      EffectiveRole.for(user, app).permission?(app.admin_permission)
    end
  end

  def protect(apps)
    apps = Array(apps).compact.uniq.select { guarded?(_1) }
    return yield if apps.empty?
    ApplicationRecord.transaction(requires_new: true) do
      before = apps.to_h { [ _1.id, holders(_1).size ] }
      value = yield
      apps.each do |app|
        fresh = App.find(app.id)
        raise LastAdmin.new(fresh) if before[app.id].positive? && guarded?(fresh) && holders(fresh).empty?
      end
      value
    end
  end
end
