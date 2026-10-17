require "test_helper"

# One app, three hosts and the back-channel hosts (SPECS.md §11.2, §22, §24.1).
class HostsTest < ActionDispatch::IntegrationTest
  ADMIN_PATHS = %w[/ /sso/callback /dev/admin_sign_in].freeze
  BACK_CHANNEL_GETS = %w[/.well-known/openid-configuration /oauth/jwks /oauth/userinfo /api/v1/access /api/v1/access/x].freeze
  BACK_CHANNEL_POSTS = %w[/oauth/token /oauth/introspect /oauth/revoke /oauth/userinfo].freeze

  def routes_of(controller_prefix)
    Rails.application.routes.routes.select { _1.defaults[:controller].to_s.start_with?(controller_prefix) }
  end

  def concrete_path(route) = route.path.spec.to_s.sub("(.:format)", "").gsub(/:\w+/, "1")

  test "/up answers on every host and on the container's own address, without the database" do
    [ auth_host, index_host, admin_host, internal_host, "127.0.0.1:3050" ].each do |host|
      host! host
      get "/up"
      assert_response :success, host
    end
  end

  test "/up/ready checks the database" do
    get "/up/ready"
    assert_response :success
    assert_equal "ok", response.parsed_body["database"]
  end

  test "config.hosts is exactly the three hosts and the back-channel hosts" do
    assert_equal %w[auth.example.com index.example.com admin.example.com auth-internal.example.com:3050], Rails.application.config.hosts
  end

  test "any other host is refused" do
    [ "evil.example", "www.example.com", "auth-internal.example.com:4000" ].each do |host|
      host! host
      get "/"
      assert_response :forbidden, host
    end
  end

  test "admin routes do not exist on the auth host" do
    sign_in_as users(:mwi)
    %w[/sso/callback /dev/admin_sign_in /users /signed_out].each do |path|
      get path
      assert_response :not_found, path
    end
    delete "/session"
    assert_response :redirect, "the auth host's sign out is its own route"
  end

  test "the index host serves the index, its sign-in and nothing of the auth or admin hosts" do
    on_index_host!
    %w[/sign_in /dev/sign_in /auth/entra_id/callback /waiting /oauth/authorize /oauth/logout /.well-known/openid-configuration
       /oauth/jwks /api/v1/access /users /dev/admin_sign_in /anything].each do |path|
      get path
      assert_response :not_found, path
    end
    post "/auth/entra_id"
    assert_response :not_found, "no Entra sign-in on the index host"
    post "/oauth/token"
    assert_response :not_found
    get "/"
    assert_equal [ auth_host, "/oauth/authorize" ], [ URI(response.location).host, URI(response.location).path ]
  end

  test "every index route is a 404 on the auth and admin hosts" do
    index_routes = routes_of("index/")
    assert_operator index_routes.size, :>=, 9
    sign_in_as users(:mwi)
    [ auth_host, admin_host ].each do |host|
      host! host
      index_routes.each do |route|
        path = concrete_path(route)
        next if path == "/" || path == "/session" || (path == "/sso/callback" && host == admin_host) ||
                (path.start_with?("/tokens", "/groups/", "/apps/") && host == admin_host) # the same paths, that host's own routes
        process (route.verb.presence || "GET").split("|").first.downcase.to_sym, path
        assert_response :not_found, "#{route.verb} #{path} on #{host}"
      end
    end
  end

  test "the admin host serves nothing but the admin UI" do
    on_admin_host!
    %w[/sign_in /dev/sign_in /auth/entra_id/callback /waiting /profile /signed_out /oauth/jwks /anything].each do |path|
      get path
      assert_response :not_found, path
    end
    post "/auth/entra_id"
    assert_response :not_found, "no Entra sign-in on the admin host"
    get "/"
    assert_admin_sign_in_started
  end

  test "an auth session cookie is no session on the admin or index host" do
    sign_in_as users(:mwi)
    plain = Session.start!(user: users(:mwi), kind: "home").last
    on_admin_host!
    get "/", headers: { "Cookie" => cookie_header("admin_session" => signed_cookie("admin_session", plain)) }
    assert_admin_sign_in_started
    on_index_host!
    get "/", headers: { "Cookie" => cookie_header("index_session" => signed_cookie("index_session", plain)) }
    assert_equal "/oauth/authorize", URI(response.location).path
  end

  test "an admin or index session cookie is no session on the auth host" do
    [ "admin", "index" ].each do |kind|
      plain = Session.start!(user: users(:mwi), kind: kind).last
      on_auth_host!
      get "/", headers: { "Cookie" => cookie_header("home_session" => signed_cookie("home_session", plain)) }
      assert_redirected_to "/sign_in", kind
      # A cookie signed for the other name is not accepted either.
      get "/", headers: { "Cookie" => cookie_header("home_session" => signed_cookie("#{kind}_session", plain)) }
      assert_redirected_to "/sign_in", kind
    end
  end

  test "an index session cookie is no session on the admin host and an admin one none on the index host" do
    index_plain = Session.start!(user: users(:mwi), kind: "index").last
    admin_plain = Session.start!(user: users(:mwi), kind: "admin").last
    on_admin_host!
    get "/", headers: { "Cookie" => cookie_header("admin_session" => signed_cookie("admin_session", index_plain)) }
    assert_admin_sign_in_started
    on_index_host!
    get "/", headers: { "Cookie" => cookie_header("index_session" => signed_cookie("index_session", admin_plain)) }
    assert_equal "/oauth/authorize", URI(response.location).path
  end

  test "correctly signed cookies are accepted (the checks above are meaningful)" do
    plain = Session.start!(user: users(:mwi), kind: "home").last
    get "/", headers: { "Cookie" => cookie_header("home_session" => signed_cookie("home_session", plain)) }
    assert_redirected_to "http://index.example.com/"
    plain = Session.start!(user: users(:mwi), kind: "index").last
    on_index_host!
    get "/", headers: { "Cookie" => cookie_header("index_session" => signed_cookie("index_session", plain)) }
    assert_response :success
  end

  # --- the back-channel hosts (AUTH_INTERNAL_HOSTS, §24.1) -------------------------------------------------

  test "an internal host answers the back-channel endpoints and nothing else" do
    on_internal_host!
    get "/.well-known/openid-configuration"
    assert_response :success
    get "/oauth/jwks"
    assert_response :success
    get "/api/v1/access"
    assert_response :unauthorized, "the API, asking for client authentication"
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: "nobody" }
    assert_response :unauthorized
    post "/oauth/introspect", params: { token: "x" }
    assert_response :unauthorized
    post "/oauth/revoke", params: { token: "x", client_id: "nobody" }
    assert_response :unauthorized
    get "/oauth/userinfo"
    assert_response :unauthorized

    %w[/ /sign_in /dev/sign_in /waiting /oauth/authorize /oauth/logout /auth/entra_id/callback /profile /tokens /sso/callback
       /users /signed_out /up/../sign_in /anything].each do |path|
      get path
      assert_response :not_found, path
    end
    post "/auth/entra_id"
    assert_response :not_found, "no Entra sign-in on an internal host"
    post "/oauth/logout"
    assert_response :not_found
    delete "/session"
    assert_response :not_found
  end

  # OmniAuth matches /auth/... case-insensitively, so an upper-case path must not reach it on another host either.
  test "Entra's paths in any case are 404 on the index, admin and internal hosts, with nothing audited" do
    [ -> { on_index_host! }, -> { on_admin_host! }, -> { on_internal_host! } ].each do |switch|
      switch.call
      assert_no_difference -> { AuditEvent.count } do
        %w[/AUTH/entra_id/callback /Auth/Entra_Id/callback /AUTH/failure].each do |path|
          get path, params: { state: "x", code: "y" }
          assert_response :not_found, "#{path} on #{host}"
        end
        post "/AUTH/entra_id"
        assert_response :not_found, "POST /AUTH/entra_id on #{host}"
      end
    end
  end

  test "an internal host's answers name APP_URL, never the Host header" do
    on_internal_host!
    get "/.well-known/openid-configuration"
    doc = response.parsed_body
    assert_equal "http://auth.example.com", doc["issuer"]
    %w[authorization_endpoint token_endpoint userinfo_endpoint jwks_uri revocation_endpoint introspection_endpoint end_session_endpoint].each do |key|
      assert doc[key].start_with?("http://auth.example.com/oauth/"), "#{key}: #{doc[key]}"
    end
    assert_no_match "auth-internal", response.body
    post "/oauth/introspect", params: {}, headers: { "Authorization" => "Basic bad" }
    assert_no_match "auth-internal", response.headers["WWW-Authenticate"].to_s
  end

  test "without AUTH_INTERNAL_HOSTS the internal host is no host of the app" do
    host = internal_host
    with_auth_config(internal_hosts: []) do
      host! host
      get "/.well-known/openid-configuration"
      assert_response :not_found
    end
  end

  test "the back-channel paths on an internal host match exactly (no prefix tricks)" do
    on_internal_host!
    %w[/oauth/jwks/x /oauth/tokens /.well-known/openid-configuration/x /api/v1 /api/v2/access].each do |path|
      get path
      assert_response :not_found, path
    end
  end
end
