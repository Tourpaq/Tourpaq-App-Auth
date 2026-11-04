# What a user ends up with in an app (SPECS.md §5.3, §23.2):
#
# 1. A disabled user, or a disabled app, is always no access.
# 2. A direct grant to the user wins, whatever the groups say: it may lower the role, raise it, or
#    be "no access" (a grant without a role).
# 3. Otherwise the highest role among the grants to the user's groups, by the app's role order.
#    On a tie the group whose name sorts first is named as the source.
# 4. Otherwise no access.
#
# In a multiple-roles app (§23.2) rules 2 and 3 become a union: the user holds every role of their direct
# grants and of their groups' grants, and their permissions are the union of those roles' permissions. A
# direct "no access" grant still overrides everything; role order does not matter.
#
#   result = EffectiveRole.for(user, app)
#   result.access?        # true when there is a role (single) or at least one role (multiple)
#   result.role           # AppRole or nil (always nil in a multiple-roles app)
#   result.role_key       # "responder" or nil
#   result.source         # "direct", the group's name, or nil (no grant applies); multiple-roles apps:
#                         #   "direct" for a direct no access, else nil (each held role has its sources)
#   result.group          # the Group the role comes from, or nil
#   result.held           # [Held(role, sources)]: every role held, sorted by name; sources are "direct"
#                         #   and/or group names (a single-role app has at most one)
#   result.role_keys      # ["Finance readers", "Management"] (single-role app: [role_key] or [])
#   result.permissions    # sorted union of the held roles' permissions, "*" kept as is ([] for single-role apps)
#   result.permission_sources  # [[key, [Held …]]]: which held roles give each permission
#   result.audit_value    # what audit events record: the role key, the sorted role keys, or nil
#   result.to_s           # "responder, from RO Dev" / "admin, direct" / "no access (direct)" / "no access"
#                         #   multiple: "Finance readers (direct), Support (from RO Dev)"
#
#   EffectiveRole.apps_for(user)          # [Result] with access, active apps, ordered by app name
#   EffectiveRole.members_of(app)         # [Result] for every active user with access, ordered by name
#   EffectiveRole.roles_for(user, app)    # [Held] (result.held)
#   EffectiveRole.permissions_for(user, app)  # [[key, [Held …]]] (result.permission_sources)
#
# This is what the ID token, the access API and token introspection report.
#
# Channels (§25): every method takes channel: "web" (the default: sign-in, the ID token, the access API, an app's own
# personal tokens) or "mcp" (through the MCP Gateway). The rules above apply to each channel's grants on their own,
# and an app without the channel gives nobody access on it. The gateway app (App#gateway?) is derived: on the MCP
# channel a user has its lowest role (source "MCP access") while they hold an MCP role in at least one other active
# app, unless a direct grant on the gateway says otherwise (a direct "no access" is the switch for one person).
#
#   EffectiveRole.for(user, app, channel: "mcp")
#   EffectiveRole.apps_for(user, channel: "mcp")
#   EffectiveRole.mcp_backends_for(user)   # [Result] in the apps behind the gateway, by slug (introspection's mcp_access)
class EffectiveRole
  DERIVED_SOURCE = "MCP access".freeze
  # A role the user holds and where it comes from ("direct" first, then group names).
  Held = Data.define(:role, :sources) do
    def key = role.key
    def direct? = sources.include?("direct")
    def groups = sources - [ "direct" ]
    def to_s = "#{role.key} (#{sources_text})"
    def sources_text = sources.map { _1 == "direct" ? "direct" : "from #{_1}" }.join(", ")
  end

  Result = Data.define(:user, :app, :role, :source, :group, :held, :channel) do
    def initialize(channel: "web", **fields) = super(channel: channel, **fields)

    def multiple? = app&.multiple_roles? || false
    def access? = multiple? ? held.any? : !role.nil?
    def role_key = role&.key
    def direct? = source == "direct"
    def from_group? = !group.nil?
    def role_keys = held.map(&:key)

    def permissions
      return [] unless multiple?
      held.flat_map { _1.role.permissions }.uniq.sort
    end

    def permission?(key) = permissions.include?(AppRole::WILDCARD) || permissions.include?(key.to_s)

    def permission_sources
      permissions.map { |key| [ key, held.select { _1.role.permissions.include?(key) } ] }
    end

    def audit_value
      return role_keys.presence if multiple?
      role_key
    end

    def to_s
      if multiple?
        return direct? ? "no access (direct)" : "no access" if held.empty?
        return held.map(&:to_s).join(", ")
      end
      if role
        direct? ? "#{role.key}, direct" : "#{role.key}, from #{source}"
      else
        direct? ? "no access (direct)" : "no access"
      end
    end
  end

  class << self
    def for(user, app, channel: "web")
      channel = channel.to_s
      return none(user, app, channel) if user.nil? || app.nil? || user.disabled? || app.disabled? || !app.channel?(channel)
      direct = Grant.for_users.on(channel).includes(:app_role).where(app_id: app.id, subject_id: user.id).to_a
      group_grants = Grant.for_groups.on(channel).where(app_id: app.id, subject_id: user.group_memberships.select(:group_id))
                          .includes(:app_role, :subject).to_a
      resolve(user, app, direct, group_grants, channel)
    end

    def roles_for(user, app, channel: "web") = self.for(user, app, channel: channel).held
    def permissions_for(user, app, channel: "web") = self.for(user, app, channel: channel).permission_sources

    # Every active app the user has a role in on the channel.
    def apps_for(user, channel: "web")
      channel = channel.to_s
      return [] if user.nil? || user.disabled?
      apps = App.active.with_channel(channel).ordered.includes(:roles).to_a
      direct = Grant.for_users.on(channel).where(subject_id: user.id).includes(:app_role).group_by(&:app_id)
      by_app = Grant.for_groups.on(channel).where(subject_id: user.group_memberships.select(:group_id))
                    .includes(:app_role, :subject).group_by(&:app_id)

      results = apps.reject(&:gateway?).filter_map do |app|
        r = resolve(user, app, direct.fetch(app.id, []), by_app.fetch(app.id, []), channel)
        r if r.access?
      end
      gateways = apps.select(&:gateway?).filter_map do |app|
        r = resolve(user, app, direct.fetch(app.id, []), by_app.fetch(app.id, []), channel, backends: results)
        r if r.access?
      end
      (results + gateways).sort_by { [ _1.app.name, _1.app.id ] }
    end

    # The apps behind the MCP Gateway the user has an MCP role in, sorted by slug: what introspecting a gateway
    # token reports as mcp_access (§25.3).
    def mcp_backends_for(user) = apps_for(user, channel: "mcp").reject { _1.app.gateway? }.sort_by { _1.app.slug }

    # Every active user with a role in the app on the channel.
    def members_of(app, channel: "web")
      channel = channel.to_s
      return [] if app.nil? || app.disabled? || !app.channel?(channel)
      return User.active.ordered.map { self.for(_1, app, channel: channel) }.select(&:access?) if app.gateway?
      grants = app.grants.on(channel).includes(:app_role, :subject).to_a
      direct = grants.select { _1.subject_type == "User" }.group_by(&:subject_id)
      group_grants = grants.select { _1.subject_type == "Group" }.group_by(&:subject_id)
      memberships = GroupMembership.where(group_id: group_grants.keys).pluck(:user_id, :group_id)
                                   .group_by(&:first).transform_values { |rows| rows.map(&:last) }

      user_ids = (direct.select { |_, list| list.any?(&:app_role_id) }.keys + memberships.keys).uniq
      User.active.where(id: user_ids).ordered.filter_map do |user|
        from_groups = memberships.fetch(user.id, []).flat_map { group_grants.fetch(_1, []) }
        r = resolve(user, app, direct.fetch(user.id, []), from_groups, channel)
        r if r.access?
      end
    end

    private

    # direct: the user's own grants in the app on the channel; group_grants: the grants to the user's groups.
    # backends: for a gateway app, the user's MCP results elsewhere when the caller has them already.
    def resolve(user, app, direct, group_grants, channel, backends: nil)
      return none(user, app, channel) if user.disabled? || app.disabled? || !app.channel?(channel)
      return resolve_multiple(user, app, direct, group_grants, channel) if app.multiple_roles?
      resolved = resolve_single(user, app, direct, group_grants, channel)
      return resolved unless app.gateway? && channel == "mcp" && resolved.source.nil?
      # Nothing granted on the gateway itself: derived from the MCP roles in the apps behind it.
      backends ||= apps_for(user, channel: "mcp").reject { _1.app.gateway? }
      backends.any? && app.lowest_role ? result(user, app, app.lowest_role, DERIVED_SOURCE, nil, channel) : resolved
    end

    def resolve_single(user, app, direct, group_grants, channel)
      if (grant = direct.first)
        result(user, app, grant.app_role, "direct", nil, channel)
      elsif (best = highest(group_grants))
        result(user, app, best.app_role, best.subject.name, best.subject, channel)
      else
        none(user, app, channel)
      end
    end

    def resolve_multiple(user, app, direct, group_grants, channel)
      return result(user, app, nil, "direct", nil, channel, held: []) if direct.any?(&:no_access?)
      sources = Hash.new { |hash, role| hash[role] = [] }
      direct.each { sources[_1.app_role] << "direct" }
      group_grants.select(&:app_role).sort_by { _1.subject.name.downcase }.each { sources[_1.app_role] << _1.subject.name }
      held = sources.map { |role, from| Held.new(role: role, sources: from.uniq) }.sort_by { [ _1.key.downcase, _1.key ] }
      result(user, app, nil, nil, nil, channel, held: held)
    end

    # The group grant with the highest role position; ties go to the group name that sorts first.
    def highest(group_grants)
      group_grants.compact.select(&:app_role).min_by { |g| [ -g.app_role.position, g.subject.name.downcase ] }
    end

    def result(user, app, role, source, group, channel, held: nil)
      held ||= role ? [ Held.new(role: role, sources: [ source ]) ] : []
      Result.new(user: user, app: app, role: role, source: source, group: group, held: held, channel: channel)
    end

    def none(user, app, channel = "web") = result(user, app, nil, nil, nil, channel)
  end
end
