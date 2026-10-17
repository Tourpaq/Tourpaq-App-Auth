# The token endpoint's two grants (SPECS.md §7, §10), used by POST /oauth/token and, in-process, by
# the admin host's callback (§11.2). Each returns the token response as a Hash, or raises Oidc::Error.
#
#   Oidc::TokenGrant.authorization_code(client:, code:, redirect_uri:, code_verifier:)
#   Oidc::TokenGrant.refresh_token(client:, refresh_token:)
#
# Authorization code: single use (a second use is refused and revokes what the first one issued),
# CODE_TTL, bound to the client and the exact redirect URI, PKCE S256 checked when the authorization
# request had a challenge (always, for public and internal clients). The user must still be active
# with access, and the auth session behind the code must not have ended.
#
# What is issued:
# - every client: an ID token (5 minutes);
# - web and extension clients: an opaque access token tpx_<slug>_… (1 hour). A web client's access
#   token is only good for /oauth/userinfo; an extension's is also what its app introspects (§10);
# - extension clients that asked for offline_access: a rotating refresh token tpr_<slug>_…, refused
#   after 30 days unused and in any case SESSION_MAX_DAYS after the Entra sign-in behind it.
# The internal clients get the ID token only, plus "entra_authenticated_at" (they have no app, and the exchange
# never leaves the process).
#
# Refresh: extension clients only. Each use retires the token and returns a new pair; presenting a
# retired token again revokes the whole chain and is audited (oauth.refresh_reused).
module Oidc
  module TokenGrant
    SUPPORTED_SCOPES = %w[openid email profile offline_access].freeze
    VERIFIER_FORMAT = /\A[A-Za-z0-9\-._~]{43,128}\z/

    module_function

    def authorization_code(client:, code:, redirect_uri:, code_verifier:)
      record = code.present? ? AuthorizationCode.includes(:user, :session).find_by(code_digest: HashedToken.digest(code)) : nil
      raise Error.new("invalid_grant", "The authorization code is not valid") unless record && record.client_id == client.id

      # Single use: claim it before anything else, so two concurrent exchanges cannot both succeed.
      unless AuthorizationCode.where(id: record.id, used_at: nil).update_all(used_at: Time.current) == 1
        OauthToken.where(chain_id: chain_id_for(record), revoked_at: nil).update_all(revoked_at: Time.current, updated_at: Time.current)
        raise Error.new("invalid_grant", "The authorization code has already been used")
      end
      raise Error.new("invalid_grant", "The authorization code has expired") if record.expired?
      raise Error.new("invalid_grant", "redirect_uri does not match the authorization request") unless record.redirect_uri == redirect_uri.to_s
      verify_pkce!(record, code_verifier, client)

      user = record.user
      raise Error.new("invalid_grant", "The user no longer has access") unless Access.allowed?(user, client)
      raise Error.new("invalid_grant", "The sign-in behind this code has ended") if record.session && !record.session.active?

      scopes = record.scope.to_s.split
      response = { "token_type" => "Bearer", "scope" => scopes.join(" "),
                   "id_token" => IdToken.issue(user: user, client: client, nonce: record.nonce, auth_time: record.auth_time) }
      # The tokens count from the Entra sign-in behind the auth session (§10), not from Entra's auth_time
      # (when credentials were last typed), which can be older than SESSION_MAX_DAYS.
      signed_in_at = record.session&.entra_authenticated_at || record.auth_time
      # An internal client's exchange never leaves the process: it also learns when the Entra sign-in behind the
      # auth session was, so the index host's session cannot outlive SESSION_MAX_DAYS from it (§24.1).
      return response.merge("entra_authenticated_at" => signed_in_at&.to_i) if client.internal?

      chain = chain_id_for(record)
      _access, access_plain = issue_token("access", client: client, user: user, chain_id: chain, scope: record.scope,
                                          auth_time: signed_in_at, expires_at: OauthToken::ACCESS_TTL.from_now)
      response.merge!("access_token" => access_plain, "expires_in" => OauthToken::ACCESS_TTL.to_i)
      if client.extension? && scopes.include?("offline_access")
        _refresh, refresh_plain = issue_token("refresh", client: client, user: user, chain_id: chain, scope: record.scope,
                                              auth_time: signed_in_at, expires_at: refresh_expiry(signed_in_at))
        response["refresh_token"] = refresh_plain
      end
      response
    end

    def refresh_token(client:, refresh_token:)
      raise Error.new("unauthorized_client", "Only extension clients use refresh tokens") unless client.extension?
      token = refresh_token.present? ? OauthToken.refresh.includes(:user, :client).find_by(token_digest: HashedToken.digest(refresh_token)) : nil
      raise Error.new("invalid_grant", "The refresh token is not valid") unless token && token.client_id == client.id

      refuse_reuse!(token) if token.retired?
      raise Error.new("invalid_grant", "The refresh token has been revoked or has expired") if token.revoked? || token.expired?

      user = token.user
      unless Access.allowed?(user, client)
        token.revoke_chain!
        raise Error.new("invalid_grant", "The user no longer has access")
      end

      response = OauthToken.transaction do
        refresh, refresh_plain = issue_token("refresh", client: client, user: user, chain_id: token.chain_id, scope: token.scope,
                                             auth_time: token.auth_time, expires_at: refresh_expiry(token.auth_time))
        # Retire the presented token; zero rows means a concurrent request already did (a copy in use).
        unless OauthToken.where(id: token.id, replaced_by_id: nil, revoked_at: nil).update_all(replaced_by_id: refresh.id, updated_at: Time.current) == 1
          raise ActiveRecord::Rollback
        end
        _access, access_plain = issue_token("access", client: client, user: user, chain_id: token.chain_id, scope: token.scope,
                                            auth_time: token.auth_time, expires_at: OauthToken::ACCESS_TTL.from_now)
        { "token_type" => "Bearer", "access_token" => access_plain, "expires_in" => OauthToken::ACCESS_TTL.to_i,
          "refresh_token" => refresh_plain, "scope" => token.scope.to_s }
      end
      response || refuse_reuse!(token.reload)
    end

    # Scopes we grant from a request's scope parameter (unknown ones are dropped).
    def granted_scopes(requested) = (requested.to_s.split & SUPPORTED_SCOPES)

    def chain_id_for(code) = Digest::SHA256.hexdigest("chain:#{code.code_digest}").first(32)

    def refresh_expiry(auth_time)
      [ OauthToken::REFRESH_IDLE.from_now, (auth_time || Time.current) + Rails.configuration.x.auth.session_max ].min
    end

    def issue_token(kind, client:, user:, chain_id:, scope:, auth_time:, expires_at:)
      token = OauthToken.new(kind: kind, client: client, user: user, chain_id: chain_id, scope: scope,
                             auth_time: auth_time, expires_at: expires_at)
      plain = token.assign_new_token(prefix: OauthToken.prefix_for(kind, client.app))
      token.save!
      [ token, plain ]
    end

    def verify_pkce!(record, verifier, client)
      if record.code_challenge.blank?
        raise Error.new("invalid_grant", "PKCE is required for this client") if client.requires_pkce? || client.internal?
        raise Error.new("invalid_grant", "code_verifier without a code_challenge") if verifier.present?
        return
      end
      raise Error.new("invalid_grant", "code_verifier is missing or malformed") unless verifier.to_s.match?(VERIFIER_FORMAT)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier.to_s), padding: false)
      raise Error.new("invalid_grant", "PKCE verification failed") unless ActiveSupport::SecurityUtils.secure_compare(challenge, record.code_challenge)
    end

    # A retired refresh token presented again: somebody holds a copy. The whole chain goes.
    def refuse_reuse!(token)
      token.revoke_chain!
      AuditEvent.record("oauth.refresh_reused", subject: token.user, actor: nil, app: token.client.app,
                        data: { client_id: token.client.client_id, chain_id: token.chain_id, hint: token.token_hint })
      raise Error.new("invalid_grant", "The refresh token has already been used")
    end
  end
end
