# The config API (SPECS.md §25.7): this app's access setup, read only, for its admins through the MCP Gateway.
#
#   GET /api/v1/config                  every app (channels, roles, clients), every group, the admins
#   GET /api/v1/config/apps/:slug       one app, its grants and its effective members per channel
#   GET /api/v1/config/users/:user      one person (email or sub): groups, grants, effective access, personal tokens
#   GET /api/v1/config/groups/:name     one group: members and grants
#   GET /api/v1/config/whoami           the caller, when they may read this (the gateway asks before it shows the
#                                       environment from Coolify)
#
# The caller is the MCP Gateway with a token exchanged for the app "auth-config" (Bearer tpe_auth-config_…, §25.5),
# so it names the person: the token must be usable (their MCP role in auth-config) and the person an active admin
# (User#admin), else 401 / 403. Answers never hold a secret: no client secrets or their hints, no token values,
# digests or hints, no Entra ids. Each admin's reads are audited as config.read at most once per AUDIT_EVERY.
class Api::V1::ConfigController < ActionController::API
  APP_SLUG = "auth-config".freeze
  AUDIT_EVERY = 5.minutes

  before_action :set_current_request
  before_action :authenticate_admin!
  rate_limit to: 120, within: 1.minute, store: RateLimitStore.store,
             by: -> { "config:#{@token.user_id}" }, with: -> { RateLimitStore.json_refusal(self) }
  after_action :audit_read

  def index
    apps = App.ordered.includes(:roles, clients: :client_secrets).to_a
    groups = Group.ordered.includes(:group_memberships).to_a
    render json: {
      apps: apps.map { app_summary(_1) },
      groups: groups.map { { name: _1.name, description: _1.description, staff: _1.staff, members: _1.group_memberships.size } },
      admins: User.admins.ordered.map { person_brief(_1) }
    }
  end

  def show_app
    app = App.includes(:roles, clients: :client_secrets).find_by(slug: params[:slug].to_s)
    return not_found("No app #{params[:slug]}") unless app
    grants = app.grants.includes(:app_role, :subject).order(:channel, :subject_type, :id).map { grant_entry(_1, subject: true) }
    members = app.channels.to_h do |channel|
      [ channel, EffectiveRole.members_of(app, channel: channel).map { access_entry(_1).merge(person_brief(_1.user)) } ]
    end
    render json: app_summary(app).merge(grants: grants, members: members)
  end

  def show_user
    value = params[:user].to_s.strip
    user = User.find_by(sub: value) || User.find_by_email(value)
    return not_found("No person #{value}") unless user
    access = App::CHANNELS.flat_map do |channel|
      EffectiveRole.apps_for(user, channel: channel).map { access_entry(_1).merge(app: _1.app.slug) }
    end
    render json: {
      user: person_brief(user).merge(sub: user.sub, bound: user.bound?, last_login_at: user.last_login_at,
                                     sessions_valid_after: user.sessions_valid_after, created_at: user.created_at),
      groups: user.groups.ordered.pluck(:name),
      grants: user.grants.includes(:app, :app_role).order(:app_id, :channel).map { grant_entry(_1, app: true) },
      access: access,
      personal_tokens: user.personal_tokens.includes(:app).recent_first.limit(50).map do |token|
        { name: token.name, app: token.app.slug, scope: token.scope, created_at: token.created_at, expires_at: token.expires_at,
          last_used_at: token.last_used_at, revoked: token.revoked?, active: token.active? }
      end
    }
  end

  def show_group
    group = Group.find_by(name: params[:name].to_s)
    return not_found("No group #{params[:name]}") unless group
    render json: {
      group: { name: group.name, description: group.description, staff: group.staff },
      members: group.users.ordered.map { person_brief(_1) },
      grants: group.grants.includes(:app, :app_role).order(:app_id, :channel).map { grant_entry(_1, app: true) }
    }
  end

  def whoami
    render json: person_brief(@token.user).merge(sub: @token.user.sub)
  end

  private

  def set_current_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel = "api"
  end

  def authenticate_admin!
    bearer = request.authorization.to_s[/\ABearer\s+(\S+)\z/, 1].to_s
    @token = ExchangedToken.find_by_plain(bearer) if bearer.start_with?("#{ExchangedToken::PREFIX}#{APP_SLUG}_")
    unless @token && @token.app.slug == APP_SLUG && @token.usable?
      @token = nil
      return render(json: { error: "invalid_token", error_description: "An MCP Gateway token exchanged for #{APP_SLUG} is required" },
                    status: :unauthorized)
    end
    return if @token.user.admin? && @token.user.active?
    render json: { error: "forbidden", error_description: "Only Tourpaq Auth admins may read its configuration" }, status: :forbidden
  end

  def audit_read
    return unless @token && response.successful?
    recent = AuditEvent.where(action: "config.read", actor: @token.user).where(created_at: AUDIT_EVERY.ago..).exists?
    return if recent
    AuditEvent.record("config.read", subject: @token.user, actor: @token.user, app: @token.app,
                      data: { path: request.path, client_id: @token.client.client_id })
  end

  def not_found(message) = render(json: { error: "not_found", error_description: message }, status: :not_found)

  def app_summary(app)
    {
      slug: app.slug, name: app.name, description: app.description, url: app.url, channels: app.channels,
      gateway: app.gateway?, multiple_roles: app.multiple_roles?, show_in_launcher: app.show_in_launcher,
      disabled: app.disabled?, role_claim: app.role_claim, token_scopes: app.token_scopes,
      roles: app.roles.map { |role| { key: role.key, description: role.description }.merge(app.multiple_roles? ? { permissions: role.permissions } : {}) },
      clients: app.clients.sort_by(&:client_id).map { client_entry(_1) }
    }
  end

  def client_entry(client)
    secrets = client.client_secrets.select(&:active?)
    { client_id: client.client_id, kind: client.kind, name: client.name, active: client.active?,
      redirect_uris: client.redirect_uris, post_logout_redirect_uris: client.post_logout_redirect_uris,
      secrets: { active: secrets.size, newest_created_at: secrets.map(&:created_at).max,
                 next_expiry: secrets.filter_map(&:expires_at).min, last_used_at: secrets.filter_map(&:last_used_at).max } }
  end

  def grant_entry(grant, subject: false, app: false)
    entry = { channel: grant.channel, role: grant.app_role&.key || "no access" }
    entry[:app] = grant.app.slug if app
    if subject
      entry[:subject_type] = grant.subject_type == "Group" ? "group" : "person"
      entry[:subject] = grant.subject_type == "Group" ? grant.subject.name : grant.subject.email
    end
    entry
  end

  def access_entry(result)
    entry = { channel: result.channel }
    if result.multiple?
      entry.merge(roles: result.role_keys, sources: result.held.map(&:to_s))
    else
      entry.merge(role: result.role_key, source: result.source)
    end
  end

  def person_brief(user) = { email: user.email, name: user.name, admin: user.admin?, disabled: user.disabled? }
end
