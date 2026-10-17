# Sets, adds or removes a grant from the admin UI (or the Dashboard import) and records grant.created /
# grant.changed / grant.removed with the before and after effective role of every affected user
# (SPECS.md §5.3, §12). Grants do not audit themselves; always change them through here.
#
#   grant = GrantChange.set(app:, subject: user_or_group, role: app_role)  # role nil: "no access" (users only)
#   grant.errors.any?                                                       # refused: nothing changed
#   GrantChange.remove(grant)                                               # grant.errors.any? when refused
#
# Single-role apps: `set` replaces the subject's one grant. Multiple-roles apps (§23.2): `set` (= `add`) adds one
# more role to the subject; "no access" (users only) replaces the user's role grants, and a role replaces a
# no-access grant. Every change goes through the per-app last-administrator guard (AppAdminGuard): a change that
# would leave nobody with the app's admin permission comes back with an error on the grant.
#
# The audit event's subject is the user or group, its app the grant's app, and its data:
#   { "subject" => "Group RO Dev", "role_before" => "responder", "role_after" => "editor",
#     "users" => [ { "user_id", "email", "before", "after" } ] }
# where a role is the role key, "no access" for a no-access grant, or nil for no grant; a user's before/after
# in a multiple-roles app is the sorted list of role names (or nil). Grants replaced by an `add` are listed
# under "replaced".
class GrantChange
  NO_ACCESS = "no access".freeze

  def self.set(app:, subject:, role:)
    return add(app: app, subject: subject, role: role) if app.multiple_roles?
    grant = Grant.find_or_initialize_by(app: app, subject: subject)
    return grant if grant.persisted? && grant.app_role_id == role&.id

    action = grant.new_record? ? "grant.created" : "grant.changed"
    role_before = grant.persisted? ? label(grant.app_role) : nil
    grant.app_role = role
    return grant unless grant.valid?

    guarded(grant) do
      Grant.transaction do
        entries = AccessChange.track(users: affected_users(subject), apps: [ app ]) do
          AppAdminGuard.protect(app) { grant.save! }
        end
        record(action, grant, role_before, label(role), entries)
      end
    end
  end

  # Multiple-roles apps: one more role for the subject (see above). An existing identical grant is returned as is.
  def self.add(app:, subject:, role:)
    existing = Grant.where(app: app, subject: subject).includes(:app_role).to_a
    if role.nil?
      return existing.first if existing.one? && existing.first.no_access?
      replaced = existing
    else
      same = existing.detect { _1.app_role_id == role.id } and return same
      replaced = existing.select(&:no_access?)
    end
    grant = Grant.new(app: app, subject: subject, app_role: role)
    grant.replacing_ids = replaced.map(&:id)
    return grant unless grant.valid?

    guarded(grant) do
      Grant.transaction do
        entries = AccessChange.track(users: affected_users(subject), apps: [ app ]) do
          AppAdminGuard.protect(app) do
            replaced.each(&:destroy!)
            grant.save!
          end
        end
        record("grant.created", grant, nil, label(role), entries, replaced: replaced.map { label(_1.app_role) }.sort)
      end
    end
  end

  def self.remove(grant)
    guarded(grant) do
      Grant.transaction do
        role_before = label(grant.app_role)
        # A fresh copy: the caller's object may come from an earlier attempt that was refused and rolled back.
        target = Grant.find(grant.id)
        entries = AccessChange.track(users: affected_users(grant.subject), apps: [ grant.app ]) do
          AppAdminGuard.protect(grant.app) { target.destroy! }
        end
        record("grant.removed", grant, role_before, nil, entries)
      end
    end
  end

  def self.label(role) = role ? role.key : NO_ACCESS

  # Active users only: a disabled user has no access whatever the grants say.
  def self.affected_users(subject) = subject.is_a?(Group) ? subject.users.active.ordered.to_a : [ subject ]

  def self.guarded(grant)
    grant.errors.clear
    yield
    grant
  rescue AppAdminGuard::LastAdmin => e
    grant.errors.add(:base, e.message)
    grant
  end

  def self.record(action, grant, role_before, role_after, entries, replaced: [])
    data = { subject: subject_label(grant.subject), role_before: role_before, role_after: role_after,
             users: AccessChange.audit_data(entries) }
    data[:replaced] = replaced if replaced.any?
    AuditEvent.record(action, subject: grant.subject, app: grant.app, data: data)
  end

  def self.subject_label(subject) = subject.is_a?(Group) ? "Group #{subject.name}" : "User #{subject.email}"

  private_class_method :label, :affected_users, :record, :subject_label, :guarded
end
