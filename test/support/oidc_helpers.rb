# The OIDC provider in tests (SPECS.md §7–§10): play an app (client) against /oauth/*.
#
#   verifier, challenge = pkce_pair
#   get authorize_path_for(clients(:irm_web), code_challenge: challenge)   # as a signed-in browser
#   code = code_from(response)                                             # from the redirect
#   post "/oauth/token", params: { grant_type: "authorization_code", code:, redirect_uri:, code_verifier: verifier },
#                        headers: basic_auth("irm-web", secret)
#   claims = verify_id_token(response.parsed_body["id_token"], aud: "irm-web")   # against GET /oauth/jwks
#   assert_admin_sign_in_started                                           # the admin host sent us to /oauth/authorize
#
# Rate limits count in their own store (RateLimitStore), emptied before every test.
module OidcHelpers
  IRM_REDIRECT = "https://irm.app.journeybooking.eu/sso/callback".freeze
  EXTENSION_REDIRECT = "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/".freeze

  def pkce_pair
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def authorize_query(client, **overrides)
    { response_type: "code", client_id: client.client_id, redirect_uri: client.redirect_uris.first,
      scope: "openid email profile", state: "state-#{SecureRandom.hex(4)}", nonce: "nonce-#{SecureRandom.hex(4)}" }
      .merge(overrides).compact
  end

  def authorize_path_for(client, **overrides) = "/oauth/authorize?#{authorize_query(client, **overrides).to_query}"

  # The query of the redirect back to the client, as a Hash.
  def client_redirect_params(response = self.response)
    assert response.redirect?, "expected a redirect, got #{response.status}"
    URI.decode_www_form(URI(response.location).query.to_s).to_h
  end

  def code_from(response = self.response)
    client_redirect_params(response).fetch("code") { flunk "no code in #{response.location}" }
  end

  def basic_auth(client_id, secret)
    { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials(client_id, secret) }
  end

  # A web client's new secret (plain).
  def secret_for(client) = client.generate_secret!(created_by: users(:mwi))

  # Signs in (unless sign_in: false), authorizes and exchanges the code: the token response
  # (parsed), plus the "nonce" sent. For extension clients pass scope: "openid offline_access".
  def oidc_login(user, client, secret: nil, scope: "openid email profile", sign_in: true, **authorize)
    sign_in_as(user) if sign_in
    on_auth_host!
    verifier, challenge = pkce_pair
    query = authorize_query(client, scope: scope, code_challenge: challenge, code_challenge_method: "S256", **authorize)
    get "/oauth/authorize?#{query.to_query}"
    code = code_from
    params = { grant_type: "authorization_code", code: code, redirect_uri: query[:redirect_uri], code_verifier: verifier }
    headers = {}
    if secret
      headers = basic_auth(client.client_id, secret)
    else
      params[:client_id] = client.client_id
    end
    post "/oauth/token", params: params, headers: headers
    assert_response :success
    response.parsed_body.merge("nonce" => query[:nonce])
  end

  # Verifies an ID token against the JWKS the provider publishes (as an app would).
  def verify_id_token(token, aud:, nonce: nil)
    get "/oauth/jwks"
    jwks = JWT::JWK::Set.new(response.parsed_body.deep_symbolize_keys)
    claims, header = JWT.decode(token, nil, true, algorithms: [ "RS256" ], jwks: jwks, iss: AuthHosts.auth_url, verify_iss: true,
                                aud: aud, verify_aud: true, verify_expiration: true)
    assert_equal nonce, claims["nonce"] if nonce
    assert header["kid"].present?
    claims
  end

  def introspect(token, client_id: "irm-web", secret:)
    post "/oauth/introspect", params: { token: token }, headers: basic_auth(client_id, secret)
    response.parsed_body
  end

  # The admin host started its OIDC sign-in: a redirect to the auth host's /oauth/authorize as client "admin".
  def assert_admin_sign_in_started(response = self.response)
    assert response.redirect?, "expected the admin sign-in redirect, got #{response.status}"
    location = URI(response.location)
    assert_equal [ AuthHosts.auth_host, "/oauth/authorize" ], [ location.host, location.path ]
    query = URI.decode_www_form(location.query).to_h
    assert_equal [ "admin", AuthHosts.admin_callback_url, "S256" ], query.values_at("client_id", "redirect_uri", "code_challenge_method")
    query
  end

  module ClearRateLimits
    def before_setup
      RateLimitStore.store.clear
      super
    end
  end
end

ActiveSupport::TestCase.include(OidcHelpers::ClearRateLimits)
ActionDispatch::IntegrationTest.include(OidcHelpers)
