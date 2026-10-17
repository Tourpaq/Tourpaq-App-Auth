require "test_helper"

# The Entra redirect URI hop (SPECS.md §24.2), with the real strategy end to end: the registration only has
# home.app's callback, so ENTRA_REDIRECT_URI names it, the Dashboard forwards the GET (query kept) to the auth
# host's callback, and the auth host verifies state, nonce and PKCE as always. Entra's token endpoint is played
# by FakeEntra below, which refuses a code exchange whose redirect_uri is not the authorization request's (as
# Entra does) and signs the ID token with FakeEntraKeys.
class EntraRedirectHopTest < ActionDispatch::IntegrationTest
  HOP = "https://home.app.journeybooking.eu/auth/entra_id/callback".freeze

  # Entra's token endpoint, in place of the HTTP call omniauth-oauth2 makes (OAuth2::Client#get_token).
  module FakeEntra
    class << self
      attr_accessor :authorization, :keys, :exchanges
    end

    def get_token(params, *_rest, **_options)
      fake = FakeEntra
      return super unless fake.authorization
      fake.exchanges << params
      auth = fake.authorization
      problem = if params["redirect_uri"] != auth["redirect_uri"] then "redirect_uri does not match the authorization request"
      elsif Base64.urlsafe_encode64(Digest::SHA256.digest(params["code_verifier"].to_s), padding: false) != auth["code_challenge"]
        "PKCE verifier does not match"
      elsif params["code"] != "entra-code" then "unknown code"
      end
      if problem
        body = { error: "invalid_grant", error_description: problem }.to_json
        raise ::OAuth2::Error, ::OAuth2::Response.new(Faraday::Response.new(status: 400, body: body, response_headers: { "Content-Type" => "application/json" }))
      end
      now = Time.now.to_i
      tenant = Rails.configuration.x.auth.entra_tenant_id
      id_token = fake.keys.id_token({ iss: "https://login.microsoftonline.com/#{tenant}/v2.0", aud: "not-configured", iat: now, nbf: now,
                                      exp: now + 3600, nonce: auth["nonce"], tid: tenant, oid: "hop-oid-1", email: "hop.user@tourpaq.com",
                                      name: "Hop User", preferred_username: "hop.user@tourpaq.com", auth_time: now })
      ::OAuth2::AccessToken.from_hash(self, { "access_token" => "entra-access", "token_type" => "Bearer", "id_token" => id_token })
    end
  end
  ::OAuth2::Client.prepend(FakeEntra)

  setup do
    OmniAuth.config.test_mode = false
    FakeEntra.keys = EntraHelpers::FakeEntraKeys.new
    FakeEntra.exchanges = []
    OmniAuth::EntraIdToken.jwks_fetcher = FakeEntra.keys
    OmniAuth::EntraIdToken.reset_cache!
  end

  teardown do
    OmniAuth.config.test_mode = true
    FakeEntra.authorization = nil
    OmniAuth::EntraIdToken.jwks_fetcher = nil
    OmniAuth::EntraIdToken.reset_cache!
  end

  # POST /auth/entra_id on the auth host; Entra's side remembers the authorization request.
  def start_sign_in
    post "/auth/entra_id"
    location = URI(response.location)
    assert_equal "login.microsoftonline.com", location.host
    FakeEntra.authorization = Rack::Utils.parse_query(location.query)
  end

  # Entra redirects to the registered URI (home.app); the Dashboard forwards the GET with its query unchanged
  # to the auth host's own callback.
  def forwarded_callback(state: FakeEntra.authorization["state"], code: "entra-code")
    forward = URI(AuthHosts.auth_url + "/auth/entra_id/callback")
    forward.query = { code: code, state: state, session_state: "s" }.to_query
    get forward.to_s
  end

  test "with ENTRA_REDIRECT_URI on home.app: query mode, the same redirect_uri in both requests, and a session" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      auth = FakeEntra.authorization
      assert_equal [ HOP, "query", "S256" ], auth.values_at("redirect_uri", "response_mode", "code_challenge_method")
      assert auth["state"].present? && auth["nonce"].present? && auth["code_challenge"].present?
      assert auth["state"].start_with?("tpa."), "the state carries the prefix the home.app forward matches on"
      assert_operator auth["state"].length, :>, 40, "the random part is still all there"

      forwarded_callback
      assert_redirected_to "/"
      assert_equal [ HOP ], FakeEntra.exchanges.map { _1["redirect_uri"] }, "the code exchange names the same redirect_uri"
      user = User.find_by_email("hop.user@tourpaq.com")
      assert_equal [ "hop-oid-1", "home" ], [ user.entra_oid, Session.last.kind ]
      assert_equal user, Session.last.user
      assert_equal "auth.login", AuditEvent.last.action
    end
  end

  test "without ENTRA_REDIRECT_URI the auth host's own callback is the redirect_uri" do
    start_sign_in
    assert_equal "http://auth.example.com/auth/entra_id/callback", FakeEntra.authorization["redirect_uri"]
    forwarded_callback
    assert_redirected_to "/"
    assert_equal [ "http://auth.example.com/auth/entra_id/callback" ], FakeEntra.exchanges.map { _1["redirect_uri"] }
  end

  test "a code exchange with another redirect_uri than the authorization request fails" do
    with_auth_config(entra_redirect_uri: HOP) { start_sign_in }
    with_auth_config(entra_redirect_uri: "https://other.example/auth/entra_id/callback") { forwarded_callback }
    assert_response :forbidden
    assert_equal [ "https://other.example/auth/entra_id/callback" ], FakeEntra.exchanges.map { _1["redirect_uri"] }
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "invalid_credentials" ], [ event.action, event.data["reason"] ]
    assert_nil User.find_by_email("hop.user@tourpaq.com")
    assert_not Session.home.exists?(user: User.where(email: "hop.user@tourpaq.com"))
  end

  test "two sign-ins started in one browser: Entra's answer to the FIRST still signs in" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      first = FakeEntra.authorization
      start_sign_in # e.g. the auto-submitted page plus a click, or a second tab
      assert_not_equal first["state"], FakeEntra.authorization["state"]
      FakeEntra.authorization = first # Entra completes the first attempt (its PKCE challenge and nonce)
      forwarded_callback(state: first["state"])
    end
    assert_redirected_to "/"
    assert User.find_by_email("hop.user@tourpaq.com")
    assert_equal "auth.login", AuditEvent.last.action
  end

  test "two sign-ins started in one browser: the answer to the second signs in too" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      start_sign_in
      forwarded_callback
    end
    assert_redirected_to "/"
  end

  test "an attempt is used once: the same answer again is refused" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      start_sign_in
      second = FakeEntra.authorization
      forwarded_callback
      assert_redirected_to "/"
      FakeEntra.authorization = second
      forwarded_callback(state: second["state"])
    end
    assert_response :forbidden
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "csrf_detected" ], [ event.action, event.data["reason"] ]
  end

  test "the audit log says why a state did not match" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      forwarded_callback(state: "tpa.#{SecureRandom.hex(24)}")
      assert_equal "unknown_state", AuditEvent.last.data["state_check"]

      state = FakeEntra.authorization["state"]
      reset!
      on_auth_host!
      forwarded_callback(state: state)
      assert_equal "no_session_cookie", AuditEvent.last.data["state_check"]
    end
  end

  test "a state with the right prefix but the wrong random part is refused" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      forwarded_callback(state: "tpa.#{SecureRandom.hex(24)}")
    end
    assert_response :forbidden
    assert_equal "csrf_detected", AuditEvent.last.data["reason"]
    assert_empty FakeEntra.exchanges
  end

  test "the state is still verified through the hop" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      forwarded_callback(state: "forged")
    end
    assert_response :forbidden
    assert_equal "csrf_detected", AuditEvent.last.data["reason"]
    assert_empty FakeEntra.exchanges, "no code exchange for a forged state"
  end

  test "a callback in another browser (no state, nonce or PKCE verifier) is refused" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      state = FakeEntra.authorization["state"]
      reset! # a fresh browser: none of the auth host's cookies
      on_auth_host!
      forwarded_callback(state: state)
    end
    assert_response :forbidden
    assert_empty FakeEntra.exchanges
  end

  test "the nonce is still verified through the hop" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      FakeEntra.authorization["nonce"] = "another-nonce" # Entra's ID token carries a nonce we did not send
      forwarded_callback
    end
    assert_response :forbidden
    event = AuditEvent.last
    assert_equal [ "auth.login_refused", "invalid_credentials" ], [ event.action, event.data["reason"] ]
    assert_match "nonce does not match", event.data["detail"]
    assert_nil User.find_by_email("hop.user@tourpaq.com")
  end

  test "the PKCE verifier is still checked through the hop" do
    with_auth_config(entra_redirect_uri: HOP) do
      start_sign_in
      FakeEntra.authorization["code_challenge"] = Base64.urlsafe_encode64(Digest::SHA256.digest("someone else's verifier"), padding: false)
      forwarded_callback
    end
    assert_response :forbidden
    assert_equal "invalid_credentials", AuditEvent.last.data["reason"]
  end
end
