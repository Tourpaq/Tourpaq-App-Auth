# GET /.well-known/openid-configuration and GET /oauth/jwks (SPECS.md §7.1). The issuer is APP_URL
# exactly (the apps' LOGIN_ISSUER). The JWKS publishes the current and the previous signing key, so
# a key rotation (§14) signs nobody out.
class Oauth::DiscoveryController < Oauth::ApiController
  def show
    issuer = Oidc::IdToken.issuer
    expires_in 5.minutes, public: true
    render json: {
      issuer: issuer,
      authorization_endpoint: "#{issuer}/oauth/authorize",
      token_endpoint: "#{issuer}/oauth/token",
      userinfo_endpoint: "#{issuer}/oauth/userinfo",
      jwks_uri: "#{issuer}/oauth/jwks",
      revocation_endpoint: "#{issuer}/oauth/revoke",
      introspection_endpoint: "#{issuer}/oauth/introspect",
      end_session_endpoint: "#{issuer}/oauth/logout",
      response_types_supported: [ "code" ],
      response_modes_supported: [ "query" ],
      grant_types_supported: %w[authorization_code refresh_token],
      subject_types_supported: [ "public" ],
      id_token_signing_alg_values_supported: [ Oidc::SigningKeys::ALGORITHM ],
      scopes_supported: Oidc::TokenGrant::SUPPORTED_SCOPES,
      token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post none],
      revocation_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post none],
      introspection_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post],
      code_challenge_methods_supported: [ "S256" ],
      prompt_values_supported: %w[none login],
      claims_supported: %w[iss sub aud exp iat auth_time nonce email email_verified name preferred_username sessions_valid_after] +
                        App.order(:role_claim).distinct.pluck(:role_claim),
      claims_parameter_supported: false,
      request_parameter_supported: false
    }
  end

  def jwks
    expires_in 5.minutes, public: true
    render json: Oidc::SigningKeys.jwks
  end
end
