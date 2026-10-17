require "test_helper"

# LOGIN_INTERNAL_URL (the auth app's SPECS.md §24.1): server-to-server calls (discovery, JWKS, token,
# introspection, the access API, the catalogue) go to another base URL, e.g. a container name on a shared Docker
# network or host.docker.internal in local testing. The browser's URLs and the iss check stay on LOGIN_ISSUER.
class InternalUrlTest < TourpaqAuthTestCase
  Fake = TourpaqAuth::TestSupport::FakeProvider
  INTERNAL = "http://auth:3050".freeze
  ISSUER = "https://auth.example.test".freeze

  def internal(provider = nil) = provider || Fake.new(client_id: "irm-web", internal_url: INTERNAL)

  def calls_to(provider, base) = provider.requests.select { _1[:url].start_with?("#{base}/") }.map { _1[:path] }

  def test_configuration
    config = TourpaqAuth::Configuration.new("LOGIN_ISSUER" => ISSUER, "LOGIN_INTERNAL_URL" => "#{INTERNAL}/ ")
    assert_equal INTERNAL, config.internal_url, "trailing slash and blanks dropped"
    assert_equal "#{INTERNAL}/oauth/introspect", config.backchannel_endpoint("/oauth/introspect")
    assert_equal "#{ISSUER}/oauth/authorize", config.endpoint("/oauth/authorize")
    assert_equal "#{INTERNAL}/oauth/token", config.backchannel_url("#{ISSUER}/oauth/token")
    assert_equal "#{INTERNAL}/keys?x=1", config.backchannel_url("https://elsewhere.example.test/keys?x=1"), "the origin is swapped"

    plain = TourpaqAuth::Configuration.new("LOGIN_ISSUER" => ISSUER, "LOGIN_INTERNAL_URL" => " ")
    assert_nil plain.internal_url
    assert_equal "#{ISSUER}/oauth/introspect", plain.backchannel_endpoint("/oauth/introspect")
    assert_equal "#{ISSUER}/oauth/token", plain.backchannel_url("#{ISSUER}/oauth/token")
  end

  def test_discovery_comes_from_the_internal_url_and_its_back_channel_urls_move_there
    with_auth(internal) do |provider|
      doc = TourpaqAuth::Client.discovery
      assert_equal [ "/.well-known/openid-configuration" ], calls_to(provider, INTERNAL)
      assert_empty calls_to(provider, provider.issuer)
      assert_equal provider.issuer, doc["issuer"]
      %w[token_endpoint jwks_uri userinfo_endpoint introspection_endpoint revocation_endpoint].each do |key|
        assert doc[key].start_with?("#{INTERNAL}/oauth/"), "#{key}: #{doc[key]}"
      end
      assert_equal "#{provider.issuer}/oauth/authorize", doc["authorization_endpoint"], "the browser's"
      assert_equal "#{provider.issuer}/oauth/logout", doc["end_session_endpoint"], "the browser's"
    end
  end

  def test_login_sends_the_browser_to_the_issuer_and_exchanges_the_code_internally
    with_auth(internal) do |provider|
      sub = provider.add_user(email: "jjr@tourpaq.com", role: "responder")
      url, login = TourpaqAuth::Client.begin_login(redirect_uri: "https://irm.example.test/sso/callback")
      assert url.start_with?("#{provider.issuer}/oauth/authorize?"), url
      result = TourpaqAuth::Client.complete_login(login, provider.authorize(url, sub: sub))
      assert_equal [ sub, "responder" ], [ result.sub, result.role ]
      assert_equal %w[/.well-known/openid-configuration /oauth/token /oauth/jwks], calls_to(provider, INTERNAL)
      assert_empty calls_to(provider, provider.issuer), "no server-to-server call to the issuer's host"
      assert TourpaqAuth::Client.end_session_url(post_logout_redirect_uri: "https://irm.example.test/").start_with?("#{provider.issuer}/oauth/logout?")
    end
  end

  def test_the_iss_check_stays_on_login_issuer
    with_auth(internal) do |provider|
      sub = provider.add_user(email: "jjr@tourpaq.com")
      url, login = TourpaqAuth::Client.begin_login(redirect_uri: "https://irm.example.test/sso/callback")
      callback = provider.authorize(url, sub: sub, claims: { "iss" => INTERNAL })
      assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(login, callback) }
    end
  end

  def test_discovery_for_another_issuer_is_refused_through_the_internal_url_too
    with_auth(internal) do |provider|
      provider.define_singleton_method(:discovery) { super().merge(issuer: INTERNAL) }
      assert_raises(TourpaqAuth::Error) { TourpaqAuth::Client.discovery }
    end
  end

  def test_access_members_introspection_catalogue_and_reachability_use_the_internal_url
    with_auth(internal) do |provider|
      sub = provider.add_user(email: "jjr@tourpaq.com", role: "responder")
      assert TourpaqAuth::Access.check(sub).active?
      assert_includes TourpaqAuth::Access.members.members.map(&:sub), sub
      token = provider.issue_token(sub: sub, scope: "read_write")
      assert TourpaqAuth::Tokens.introspect(token).active?
      TourpaqAuth::Catalogue.push([ { key: "x:y:z" } ])
      assert TourpaqAuth::Client.reachable?
      assert_equal [ "/api/v1/access/#{sub}", "/api/v1/access", "/oauth/introspect", "/api/v1/catalogue", "/.well-known/openid-configuration" ],
                   calls_to(provider, INTERNAL)
      assert_empty calls_to(provider, provider.issuer)
    end
  end

  def test_without_it_everything_goes_to_the_issuer
    with_auth(client_id: "irm-web") do |provider|
      sub = provider.add_user(email: "jjr@tourpaq.com")
      TourpaqAuth::Access.check(sub)
      TourpaqAuth::Client.discovery
      assert_equal 2, calls_to(provider, provider.issuer).size
      assert_nil TourpaqAuth.config.internal_url
    end
  end
end
