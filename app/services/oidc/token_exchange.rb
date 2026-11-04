# The token exchange (SPECS.md §25.5, RFC 8693): the MCP Gateway trades a person's gateway token for a short-lived
# token for one app behind it, so that app sees the person (sub, email, name), their MCP-channel role and a scope no
# wider than the gateway token's, and never the gateway token itself.
#
#   Oidc::TokenExchange.call(client:, subject_token:, audience:, subject_token_type:, requested_token_type:)
#     # => { "access_token" => "tpe_logs_…", "issued_token_type" => ACCESS_TOKEN_TYPE, "token_type" => "Bearer",
#     #      "expires_in" => 300, "scope" => "read" }  or raises Oidc::Error
#
# - the caller is a web client of a gateway app (App#gateway?), else unauthorized_client;
# - subject_token is a usable personal token of that gateway app, else invalid_grant;
# - audience is the slug of an active app with the MCP channel (not a gateway) where the person holds an MCP role,
#   else invalid_target;
# - scope: the gateway token's scope when the audience has it, else the audience's lowest token scope.
# Counted per client and day ("exchange"); audited token.exchanged at most once per gateway token, app and AUDIT_EVERY.
module Oidc
  module TokenExchange
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange".freeze
    ACCESS_TOKEN_TYPE = "urn:ietf:params:oauth:token-type:access_token".freeze
    AUDIT_EVERY = 5.minutes

    module_function

    def call(client:, subject_token:, audience:, subject_token_type: ACCESS_TOKEN_TYPE, requested_token_type: nil)
      unless client&.web? && client.app&.gateway?
        raise Error.new("unauthorized_client", "Only the MCP Gateway's client may exchange tokens")
      end
      if subject_token_type.present? && subject_token_type != ACCESS_TOKEN_TYPE
        raise Error.new("invalid_request", "subject_token_type must be #{ACCESS_TOKEN_TYPE}")
      end
      if requested_token_type.present? && requested_token_type != ACCESS_TOKEN_TYPE
        raise Error.new("invalid_request", "requested_token_type must be #{ACCESS_TOKEN_TYPE}")
      end

      gateway_token = PersonalToken.find_by_plain(subject_token.to_s)
      unless gateway_token && gateway_token.app_id == client.app_id && gateway_token.usable?
        raise Error.new("invalid_grant", "The subject token is not an active MCP Gateway token")
      end

      app = App.active.mcp_backends.find_by(slug: audience.to_s)
      role = app && EffectiveRole.for(gateway_token.user, app, channel: "mcp")
      unless role&.access?
        raise Error.new("invalid_target", "No MCP access to #{audience.to_s.presence || 'that app'}")
      end

      scope = app.token_scopes.include?(gateway_token.scope) ? gateway_token.scope : app.lowest_token_scope
      token = ExchangedToken.new(personal_token: gateway_token, app: app, client: client, user: gateway_token.user,
                                 scope: scope, expires_at: ExchangedToken::TTL.from_now)
      plain = token.assign_new_token(prefix: ExchangedToken.prefix_for(app))
      token.save!
      gateway_token.touch_used!
      UsageCount.increment!(client, "exchange")
      audit(gateway_token, app, client, scope)

      { "access_token" => plain, "issued_token_type" => ACCESS_TOKEN_TYPE, "token_type" => "Bearer",
        "expires_in" => ExchangedToken::TTL.to_i, "scope" => scope }
    end

    def audit(gateway_token, app, client, scope)
      recent = AuditEvent.where(action: "token.exchanged", subject: gateway_token, app: app).where(created_at: AUDIT_EVERY.ago..).exists?
      return if recent
      AuditEvent.record("token.exchanged", subject: gateway_token, actor: gateway_token.user, app: app,
                        data: { user_id: gateway_token.user_id, client_id: client.client_id, audience: app.slug, scope: scope,
                                hint: gateway_token.token_hint })
    end
  end
end
