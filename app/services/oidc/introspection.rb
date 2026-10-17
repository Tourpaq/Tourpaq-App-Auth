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
module Oidc
  module Introspection
    INACTIVE = { "active" => false }.freeze

    module_function

    def call(client, token)
      token = token.to_s
      return INACTIVE if client&.app.nil? || token.blank? || token.length > 512
      if token.start_with?(PersonalToken::PREFIX)
        personal(client, token)
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
      token.touch_used!
      answer(client, token.user, role, token_type: "personal", scope: token.scope, exp: token.expires_at, token_name: token.name)
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
