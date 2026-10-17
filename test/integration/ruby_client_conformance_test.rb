require "test_helper"
$LOAD_PATH.unshift Rails.root.join("clients/ruby/lib").to_s
require "tourpaq_auth"

# The shared Ruby client (clients/ruby, SPECS.md §13) against this provider: the apps' side of the
# protocol, so the two cannot drift apart. The gem's HTTP seam goes into a second integration session
# (the app's server-to-server calls); the browser is the test's own session.
class RubyClientConformanceTest < ActionDispatch::IntegrationTest
  setup do
    @secret = secret_for(clients(:irm_web))
    @previous_config = TourpaqAuth.config
    server = open_session
    @server_calls = []
    @seam = lambda do |method, url, form: nil, headers: {}, timeout: 5, body: nil|
      uri = URI(url)
      @server_calls << url
      server.host!(uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}")
      server.process(method, uri.request_uri, params: body || form, headers: headers)
      [ server.response.status, server.response.body, server.response.headers.to_h ]
    end
    configure_gem("irm-web", @secret, OidcHelpers::IRM_REDIRECT)
  end

  def configure_gem(client_id, secret, redirect_uri, internal_url: nil)
    env = { "LOGIN_ISSUER" => AuthHosts.auth_url, "LOGIN_CLIENT_ID" => client_id, "LOGIN_CLIENT_SECRET" => secret,
            "LOGIN_INTERNAL_URL" => internal_url }
    TourpaqAuth.configure(env) do |config|
      config.http = @seam
      config.cache = TourpaqAuth::MemoryStore.new
      config.redirect_uri = redirect_uri
      config.logger = nil
    end
  end

  teardown { TourpaqAuth.config = @previous_config }

  test "login, access check, members sync and introspection through the gem" do
    sign_in_as users(:alice)
    url, login = TourpaqAuth::Client.begin_login
    get url
    result = TourpaqAuth::Client.complete_login(login, client_redirect_params)
    assert_equal [ users(:alice).sub, "alice@tourpaq.com", "responder" ], [ result.sub, result.email, result.role ]
    assert result.email_verified?
    assert result.authenticated_at

    check = TourpaqAuth::Access.check(result.sub)
    assert_equal [ true, "responder" ], [ check.active?, check.role ]

    members = TourpaqAuth::Access.members
    assert_includes members.members.map(&:sub), users(:alice).sub
    assert TourpaqAuth::Access.members(etag: members.etag).not_modified?

    token = PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "MCP", scope: "read_write")
    answer = TourpaqAuth::Tokens.introspect(token)
    assert_equal [ true, "personal", "read_write", "responder", users(:alice).sub ], [ answer.active?, answer.token_type, answer.scope, answer.role, answer.sub ]

    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    assert_not TourpaqAuth::Access.check(result.sub, force: true).active?
    TourpaqAuth::Tokens.forget(token)
    assert_not TourpaqAuth::Tokens.introspect(token).active?

    assert TourpaqAuth::Client.end_session_url(post_logout_redirect_uri: "https://irm.app.journeybooking.eu/").start_with?("#{AuthHosts.auth_url}/oauth/logout?")
  end

  test "a permission app (§23.2): role list and permissions at login, in the check, members and introspection; the catalogue push" do
    dashboard = create_dashboard_app(catalogue: false)
    secret = secret_for(Client.find_by!(client_id: "dashboard-web"))
    grant_dashboard(users(:alice), "Support")
    grant_dashboard(groups(:ro_dev), "Finance readers")
    configure_gem("dashboard-web", secret, "https://home.app.journeybooking.eu/sso/callback")
    permissions = %w[management:finance:view module:customers:view module:tasks:view]

    pushed = TourpaqAuth::Catalogue.push(DashboardHelpers::DASHBOARD_CATALOGUE.map { _1.transform_keys(&:to_sym) })
    assert_equal [ "dashboard", 5 ], [ pushed.app, pushed.count ]
    assert_equal DashboardHelpers::DASHBOARD_CATALOGUE.map { _1["key"] }, dashboard.reload.catalogue_keys
    assert_equal({}, pushed.unknown)

    sign_in_as users(:alice)
    url, login = TourpaqAuth::Client.begin_login
    get url
    result = TourpaqAuth::Client.complete_login(login, client_redirect_params)
    assert_equal [ nil, [ "Finance readers", "Support" ], permissions ], [ result.role, result.roles, result.permissions ]

    check = TourpaqAuth::Access.check(result.sub)
    assert_equal [ true, nil, [ "Finance readers", "Support" ], permissions ], [ check.active?, check.role, check.roles, check.permissions ]
    member = TourpaqAuth::Access.members.members.detect { _1.sub == users(:alice).sub }
    assert_equal permissions, member.permissions

    token = PersonalToken.issue!(user: users(:alice), app: dashboard, name: "Paperclip", scope: "all")
    answer = TourpaqAuth::Tokens.introspect(token)
    assert_equal [ true, "all", [ "Finance readers", "Support" ] ], [ answer.active?, answer.scope, answer.roles ]
    assert answer.permission?("management:finance:view")

    dashboard.role("Support").update!(permissions: %w[module:customers:view old:module:view])
    assert_equal({ "Support" => [ "old:module:view" ] }, TourpaqAuth::Catalogue.push(DashboardHelpers::DASHBOARD_CATALOGUE).unknown)
  end

  test "a wrong secret is a refusal, not an outage" do
    TourpaqAuth.config.client_secret = "tpcs_wrong"
    assert_raises(TourpaqAuth::Error) { TourpaqAuth::Access.check(users(:alice).sub) }
  end

  test "the gem's login refuses a code from a browser without the login (state)" do
    sign_in_as users(:alice)
    url, _login = TourpaqAuth::Client.begin_login
    get url
    _other_url, other_login = TourpaqAuth::Client.begin_login
    assert_raises(TourpaqAuth::LoginError) { TourpaqAuth::Client.complete_login(other_login, client_redirect_params) }
  end

  # SPECS.md §24.1: the app reaches the auth app over a shared Docker network (AUTH_INTERNAL_HOSTS here,
  # LOGIN_INTERNAL_URL in the gem); the browser and the issuer stay on APP_URL.
  test "the back-channel through an internal host: login, access, members, introspection, catalogue" do
    internal = "http://#{internal_host}"
    configure_gem("irm-web", @secret, OidcHelpers::IRM_REDIRECT, internal_url: internal)
    sign_in_as users(:alice)
    url, login = TourpaqAuth::Client.begin_login
    assert url.start_with?("http://auth.example.com/oauth/authorize?"), "the browser goes to the issuer: #{url}"
    get url
    result = TourpaqAuth::Client.complete_login(login, client_redirect_params)
    assert_equal [ users(:alice).sub, "responder" ], [ result.sub, result.role ]
    assert_equal "http://auth.example.com", result.claims["iss"]

    assert TourpaqAuth::Access.check(result.sub).active?
    assert_includes TourpaqAuth::Access.members.members.map(&:sub), users(:alice).sub
    token = PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "MCP", scope: "read")
    assert TourpaqAuth::Tokens.introspect(token).active?
    assert_equal 1, TourpaqAuth::Catalogue.push([ { key: "irm:incidents:view" } ]).count

    assert_operator @server_calls.size, :>=, 7
    assert @server_calls.all? { _1.start_with?("#{internal}/") }, "every server-to-server call went to the internal host: #{@server_calls.inspect}"
    paths = @server_calls.map { URI(_1).path }
    %w[/.well-known/openid-configuration /oauth/token /oauth/jwks /api/v1/access /oauth/introspect /api/v1/catalogue].each do |path|
      assert_includes paths, path
    end
    assert TourpaqAuth::Client.end_session_url(post_logout_redirect_uri: "https://irm.app.journeybooking.eu/").start_with?("http://auth.example.com/oauth/logout?")
  end

  test "an internal host is no way into the browser's endpoints" do
    on_internal_host!
    get "/oauth/authorize?#{authorize_query(clients(:irm_web)).to_query}"
    assert_response :not_found
  end
end
