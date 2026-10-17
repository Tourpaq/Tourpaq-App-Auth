require "test_helper"

class ClientTest < TourpaqAuthTestCase
  Fake = TourpaqAuth::TestSupport::FakeProvider

  def query_of(url) = URI.decode_www_form(URI(url).query).to_h

  def test_authorization_url_carries_pkce_state_nonce_scopes_and_the_redirect_uri
    with_auth(client_id: "irm-web") do |provider|
      url = TourpaqAuth::Client.authorization_url(state: "st", nonce: "no", code_verifier: "verifier",
                                                  redirect_uri: "https://irm.example.test/sso/callback", max_age: 43_200)
      query = query_of(url)
      assert url.start_with?("#{provider.issuer}/oauth/authorize?")
      assert_equal %w[code irm-web st no S256 openid\ email\ profile 43200],
                   query.values_at("response_type", "client_id", "state", "nonce", "code_challenge_method", "scope", "max_age")
      expected = [ Digest::SHA256.digest("verifier") ].pack("m0").tr("+/", "-_").delete("=")
      assert_equal expected, query["code_challenge"]
      assert_equal "https://irm.example.test/sso/callback", query["redirect_uri"]
    end
  end

  def test_redirect_uri_defaults_to_the_configuration
    with_auth do
      query = query_of(TourpaqAuth::Client.authorization_url(state: "s", nonce: "n", code_verifier: "v"))
      assert_equal "http://app.example.test/sso/callback", query["redirect_uri"]
    end
  end

  def test_the_code_exchange_uses_client_secret_basic_and_sends_the_verifier
    with_auth(client_id: "irm-web", client_secret: "s3cret") do |provider|
      TourpaqAuth::Client.exchange_code("abc", code_verifier: "ver", redirect_uri: "https://irm.example.test/cb")
      request = provider.token_requests.last
      assert_equal({ grant_type: "authorization_code", code: "abc", redirect_uri: "https://irm.example.test/cb", code_verifier: "ver" },
                   request[:form])
      assert_equal "Basic #{['irm-web:s3cret'].pack('m0')}", request[:headers]["Authorization"]
    end
  end

  def test_client_credentials_are_form_encoded_before_basic
    assert_equal "Basic #{['a%3Ab:c+d%26'].pack('m0')}", TourpaqAuth::Http.basic_auth("a:b", "c d&")
  end

  def test_a_refused_code_exchange_is_a_login_error_with_the_reason
    with_auth do |provider|
      provider.token_status = 400
      error = assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.exchange_code("abc", code_verifier: "v") }
      assert_match "Code expired", error.message
    end
  end

  def test_a_wrong_client_secret_is_refused_by_the_token_endpoint
    with_auth(env: { "LOGIN_CLIENT_SECRET" => "wrong" }) do
      assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.exchange_code("abc", code_verifier: "v") }
    end
  end

  def test_discovery_for_another_issuer_is_refused
    with_auth do |provider|
      provider.define_singleton_method(:discovery) { super().merge(issuer: "https://evil.example.test") }
      error = assert_raises(TourpaqAuth::Error) { TourpaqAuth::Client.discovery }
      assert_match "does not match", error.message
    end
  end

  def test_discovery_is_cached_for_an_hour
    with_auth do |provider|
      3.times { TourpaqAuth::Client.discovery }
      assert_equal 1, provider.requests.count { _1[:path] == "/.well-known/openid-configuration" }
      travel 3601
      TourpaqAuth::Client.discovery
      assert_equal 2, provider.requests.count { _1[:path] == "/.well-known/openid-configuration" }
    end
  end

  def test_an_unreachable_auth_app_raises_unavailable
    with_auth do |provider|
      provider.reachable = false
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Client.discovery }
      assert_raises(TourpaqAuth::Unavailable) { TourpaqAuth::Client.begin_login }
    end
  end

  def test_reachable_is_cached_for_five_minutes_and_never_raises
    with_auth do |provider|
      assert TourpaqAuth::Client.reachable?
      provider.reachable = false
      assert TourpaqAuth::Client.reachable?, "cached"
      travel 301
      refute TourpaqAuth::Client.reachable?
    end
  end

  def test_a_full_login_returns_who_signed_in_with_their_role
    with_auth(client_id: "irm-web") do |provider|
      valid_after = Time.at(TourpaqAuth.now.to_i - 3600).utc
      sub = provider.add_user(email: "JJR@tourpaq.com", name: "Jens", role: "responder", sessions_valid_after: valid_after)
      url, login = TourpaqAuth::Client.begin_login(redirect_uri: "https://irm.example.test/sso/callback")
      assert_equal %w[at nonce redirect_uri state verifier], login.keys.sort
      callback = provider.authorize(url, sub: sub)

      result = TourpaqAuth::Client.complete_login(login, callback)

      assert_kind_of TourpaqAuth::Login, result
      assert_equal sub, result.sub
      assert_equal "jjr@tourpaq.com", result.email
      assert_equal "Jens", result.name
      assert_equal "responder", result.role
      assert_equal valid_after, result.sessions_valid_after
      assert_equal "responder", result.claims["irm_role"]
      assert result.email_verified?
    end
  end

  def test_complete_login_accepts_symbol_keys
    with_auth do |provider|
      url, login = TourpaqAuth::Client.begin_login
      callback = provider.authorize(url, claims: { "sub" => "abc" })
      result = TourpaqAuth::Client.complete_login(login.transform_keys(&:to_sym), callback.transform_keys(&:to_sym))
      assert_equal "abc", result.sub
    end
  end

  def test_a_login_with_another_state_is_refused_before_the_code_is_exchanged
    with_auth do |provider|
      url, login = TourpaqAuth::Client.begin_login
      callback = provider.authorize(url)
      assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(login, callback.merge("state" => "other")) }
      assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(nil, callback) }
      assert_empty provider.token_requests
    end
  end

  def test_a_login_older_than_ten_minutes_is_refused
    with_auth do |provider|
      url, login = TourpaqAuth::Client.begin_login
      callback = provider.authorize(url)
      login["at"] -= 601
      error = assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(login, callback) }
      assert_match "10 minutes", error.message
    end
  end

  def test_an_error_from_the_auth_app_is_a_login_error
    with_auth do
      _, login = TourpaqAuth::Client.begin_login
      error = assert_raises(TourpaqAuth::LoginError) do
        TourpaqAuth::Client.complete_login(login, "error" => "access_denied", "error_description" => "No access to IRM", "state" => login["state"])
      end
      assert_match "No access to IRM", error.message
    end
  end

  def test_pkce_is_checked_by_the_fake_provider
    with_auth do |provider|
      url, login = TourpaqAuth::Client.begin_login
      callback = provider.authorize(url)
      login["verifier"] = "not-the-verifier"
      error = assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(login, callback) }
      assert_match "PKCE", error.message
    end
  end

  def test_end_session_url
    with_auth(client_id: "irm-web") do |provider|
      url = TourpaqAuth::Client.end_session_url(post_logout_redirect_uri: "https://irm.example.test/")
      assert url.start_with?("#{provider.issuer}/oauth/logout?")
      assert_equal({ "client_id" => "irm-web", "post_logout_redirect_uri" => "https://irm.example.test/" }, query_of(url))
    end
  end

  def test_not_configured
    with_auth(env: { "LOGIN_CLIENT_SECRET" => nil }) do
      refute TourpaqAuth.enabled?
      assert_raises(TourpaqAuth::NotConfigured) { TourpaqAuth::Client.discovery }
    end
  end
end
