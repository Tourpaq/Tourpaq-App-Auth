# Reordering an app's roles changes what "highest" means for group grants (SPECS.md §5.1), so the
# admin UI shows whose effective role would change before the new order is saved.
#
#   RoleReorder.preview(app, %w[viewer editor responder admin])  # => [Change(user, before, after)]
#   RoleReorder.apply!(app, keys)                                # saves, audits app.roles_reordered
#
# The preview reorders inside a transaction that is rolled back, and asks EffectiveRole as usual.
class RoleReorder
  Change = Data.define(:user, :before, :after)

  def self.preview(app, keys)
    before = members(app)
    after = nil
    App.transaction(requires_new: true) do
      App.find(app.id).reorder_roles!(keys)
      after = members(App.find(app.id))
      raise ActiveRecord::Rollback
    end
    users = (before.keys | after.keys)
    User.where(id: users).ordered.filter_map do |user|
      Change.new(user: user, before: before[user.id], after: after[user.id]) if before[user.id] != after[user.id]
    end
  end

  def self.apply!(app, keys)
    changes = preview(app, keys)
    old_order = app.role_keys
    App.transaction do
      app.reorder_roles!(keys)
      AuditEvent.record("app.roles_reordered", subject: app,
                        data: { before: old_order, after: app.role_keys,
                                users: changes.map { { "user_id" => _1.user.id, "email" => _1.user.email, "before" => _1.before, "after" => _1.after } } })
    end
    changes
  end

  def self.members(app) = EffectiveRole.members_of(app).to_h { [ _1.user.id, _1.audit_value ] }
  private_class_method :members
end
