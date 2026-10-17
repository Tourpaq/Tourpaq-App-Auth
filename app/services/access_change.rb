# The effective roles (SPECS.md §5.3) of some users in some apps before and after a change made in
# the admin UI: a grant set or removed, a group member added or removed. The audit events for those
# changes carry the before/after role of each affected user (§12), and a user who loses access to an
# app has their extension tokens for that app's clients revoked at once (§6).
#
#   entries = AccessChange.track(users: group.users, apps: [ app ]) { grant.save! }
#   entries.first.before    # "responder" or nil (no access); a multiple-roles app (§23.2): the sorted role
#                           # names, ["Finance readers", "Management"], or nil
#   AccessChange.audit_data(entries)
#     # => [ { "user_id" => 3, "email" => "…", "app" => "irm", "before" => "responder", "after" => "editor" } ]
class AccessChange
  Entry = Data.define(:user, :app, :before, :after) do
    def changed? = before != after
    def lost? = !before.nil? && after.nil?
  end

  def self.track(users:, apps:)
    users = users.to_a.uniq
    apps = apps.to_a.uniq
    before = snapshot(users, apps)
    yield
    after = snapshot(users, apps)
    entries = users.product(apps).map do |user, app|
      Entry.new(user: user, app: app, before: before[[ user.id, app.id ]], after: after[[ user.id, app.id ]])
    end
    revoke_lost_extension_tokens(entries)
    entries
  end

  def self.audit_data(entries, with_app: false)
    entries.map do |entry|
      { "user_id" => entry.user.id, "email" => entry.user.email, "before" => entry.before, "after" => entry.after }
        .tap { _1["app"] = entry.app.slug if with_app }
    end
  end

  def self.snapshot(users, apps)
    users.product(apps).to_h { |user, app| [ [ user.id, app.id ], EffectiveRole.for(user, app).audit_value ] }
  end

  # §6: "Remove access to one app: … the extension's refresh tokens for that app are revoked."
  def self.revoke_lost_extension_tokens(entries)
    entries.select(&:lost?).each do |entry|
      entry.app.clients.each { entry.user.revoke_oauth_tokens!(client: _1) }
    end
  end
  private_class_method :snapshot, :revoke_lost_extension_tokens
end
