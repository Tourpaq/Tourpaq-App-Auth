# ID tokens of the OIDC provider (SPECS.md §7.3): RS256 with the current signing key (kid in the
# header), TTL 5 minutes, audience = the client id.
#
#   Oidc::IdToken.issue(user:, client:, nonce:, auth_time:)   # the signed JWT
#   Oidc::IdToken.user_claims(user, client)                   # also what /oauth/userinfo returns
#   Oidc::IdToken.verify(token, audience:, nonce:)            # our own token → claims, or InvalidToken
#   Oidc::IdToken.verify_hint(token)                          # id_token_hint at logout: expiry ignored
#   Oidc::IdToken.issue_hint(user:, client:)                  # a minimal one for our own hosts' sign out (sub only)
module Oidc
  module IdToken
    TTL = 5.minutes
    LEEWAY = 30

    module_function

    def issuer = AuthHosts.auth_url

    def issue(user:, client:, nonce:, auth_time:)
      now = Time.current.to_i
      payload = {
        "iss" => issuer, "sub" => user.sub, "aud" => client.client_id,
        "exp" => now + TTL.to_i, "iat" => now, "auth_time" => auth_time&.to_i, "nonce" => nonce.presence
      }
      # The protocol claims always win over the user claims.
      SigningKeys.sign(user_claims(user, client).merge(payload).compact)
    end

    # A logout hint for the index host's own sign out (§11.1): signed like an ID token, but with no identity claims
    # beyond sub, because it travels in a URL.
    def issue_hint(user:, client:)
      now = Time.current.to_i
      SigningKeys.sign({ "iss" => issuer, "sub" => user.sub, "aud" => client.client_id, "exp" => now + TTL.to_i, "iat" => now })
    end

    # Identity and the role in the client's app only (the token says nothing about other apps).
    # sessions_valid_after (Unix seconds, rounded up) is left out until the user's first "sign out everywhere". A
    # multiple-roles app (§23.2) gets its role claim as a list of role names, plus "<slug>_permissions" with the
    # sorted union of their permissions ("*" passed through). Neither ever replaces another claim (App validates
    # the names against App::RESERVED_CLAIMS; this is the backstop).
    def user_claims(user, client)
      claims = {
        "sub" => user.sub, "email" => user.email, "email_verified" => true, "name" => user.name,
        "preferred_username" => user.upn.presence || user.email,
        "sessions_valid_after" => user.sessions_valid_after_epoch
      }
      app = client.app
      if app && !client.internal?
        result = EffectiveRole.for(user, app)
        if app.multiple_roles?
          add_claim(claims, app.role_claim, result.role_keys)
          add_claim(claims, app.permissions_claim, result.permissions)
        else
          add_claim(claims, app.role_claim, result.role_key)
        end
      end
      claims.compact
    end

    def add_claim(claims, name, value)
      return if name.blank? || claims.key?(name) || App::RESERVED_CLAIMS.include?(name)
      claims[name] = value
    end

    def verify(token, audience:, nonce: nil)
      claims = decode(token, verify_expiration: true, audience: audience)
      if nonce && !ActiveSupport::SecurityUtils.secure_compare(claims["nonce"].to_s, nonce.to_s)
        raise InvalidToken, "nonce does not match"
      end
      claims
    end

    # For id_token_hint (OIDC RP-Initiated Logout): signed by us and issued by us; it may have expired.
    def verify_hint(token) = decode(token, verify_expiration: false, audience: nil)

    def decode(token, verify_expiration:, audience:)
      options = { algorithms: [ SigningKeys::ALGORITHM ], jwks: SigningKeys.verifier_set, iss: issuer, verify_iss: true,
                  verify_iat: true, verify_expiration: verify_expiration, leeway: LEEWAY }
      options.merge!(aud: audience, verify_aud: true) if audience
      claims, = JWT.decode(token.to_s, nil, true, options)
      raise InvalidToken, "no subject" if claims["sub"].blank?
      claims
    rescue JWT::DecodeError => e
      raise InvalidToken, e.message
    end
  end
end
