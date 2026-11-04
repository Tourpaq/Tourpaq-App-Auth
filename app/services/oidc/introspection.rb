# Token introspection for the apps (SPECS.md §9.2, §10; RFC 7662): is this personal (tpa_<slug>_…) or
# extension (tpx_<slug>_…) token valid, for whom, with which scope and role?
#
#   Oidc::Introspection.call(client, token)   # a Hash: { "active" => false } or the §9.2 answer
#
# The caller is the app's web client. The answer is { "active" => false } and nothing else when the
# token is unknown, expired, revoked, belongs to another app, or its user is disabled or has no
# access to the app any more. Refresh tokens and web clients' access tokens are never active here.
# The role reported is the user's effective role now; the scope is the token's (personal) or the app's
# highest token scope (extension: read_write, the Dashboard's all, §23.3). Each app caps the scope by the role
# (§9.2). A multiple-roles app (§23.2) also gets "roles" and "permissions" (the sorted union), with "role" null.
# last_used_at is recorded at most once a minute.
#
# The MCP Gateway (§25): a gateway token (tpa_<gateway>_…) introspected by the gateway's client also carries
# "mcp_access", the apps behind the gateway where the person holds an MCP role (and is active: false when there are
# none). An exchanged token (tpe_<app>_…) is active only for its own app's web client, with token_type "exchanged",
# the person's MCP-channel role, the exchanged scope, "act" (the gateway's client) and the gateway token's name.
module Oidc
  module Introspection
    INACTIVE = { "active" => false }.freeze

    module_function

    def call(client, token)
      token = token.to_s
      return INACTIVE if client&.app.nil? || token.blank? || token.length > 512
      if token.start_with?(PersonalToken::PREFIX)
        personal(client, token)
      elsif token.start_with?(ExchangedToken::PREFIX)
        exchanged(client, token)
      elsif token.start_with?(OauthToken::ACCESS_PREFIX)
        extension(client, token)
      else
        INACTIVE
      end
    end

    def personal(client, plain)
      token = PersonalToken.find_by_plain(plain)
      return INACTIVE unless token && token.app_id == client.app_id && token.active?
      role = token.effective_role
      return INACTIVE unless role.access?
      result = answer(client, token.user, role, token_type: "personal", scope: token.scope, exp: token.expires_at, token_name: token.name)
      if client.app.gateway?
        access = mcp_access(token.user)
        return INACTIVE if access.empty?
        result["mcp_access"] = access
      end
      token.touch_used!
      result
    end

    def exchanged(client, plain)
      token = ExchangedToken.find_by_plain(plain)
      return INACTIVE unless token && token.app_id == client.app_id && token.usable?
      answer(client, token.user, token.effective_role, token_type: "exchanged", scope: token.scope, exp: token.expires_at,
             token_name: token.personal_token.name).merge("act" => { "client_id" => token.client.client_id })
    end

    # [{ "app", "name", "role" (+ "roles", "permissions" for a multiple-roles app) }] by slug.
    def mcp_access(user)
      EffectiveRole.mcp_backends_for(user).map do |role|
        entry = { "app" => role.app.slug, "name" => role.app.name, "role" => role.role_key }
        entry.merge!("roles" => role.role_keys, "permissions" => role.permissions) if role.app.multiple_roles?
        entry
      end
    end

    def extension(client, plain)
      token = OauthToken.access.includes(:user, client: :app).find_by(token_digest: HashedToken.digest(plain))
      return INACTIVE unless token&.client&.extension? && token.client.app_id == client.app_id && token.usable? && token.client.active?
      role = EffectiveRole.for(token.user, client.app)
      return INACTIVE unless role.access?
      token.update_columns(last_used_at: Time.current) if token.last_used_at.nil? || token.last_used_at < 1.minute.ago
      answer(client, token.user, role, token_type: "extension", scope: client.app.highest_token_scope, exp: token.expires_at, token_name: token.client.name)
    end

    def answer(client, user, role, token_type:, scope:, exp:, token_name:)
      answer = { "active" => true, "token_type" => token_type, "client_id" => client.client_id, "app" => client.app.slug,
                 "sub" => user.sub, "email" => user.email, "name" => user.name, "scope" => scope, "role" => role.role_key,
                 "exp" => exp.to_i, "token_name" => token_name }
      answer.merge!("roles" => role.role_keys, "permissions" => role.permissions) if client.app.multiple_roles?
      answer
    end
  end
end
