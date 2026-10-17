require "test_helper"

# GET /api/v1/index on the index host (SPECS.md §24.3): WWW's response shape, for the browser extension (Bearer
# tpx_index_… from the client index-extension, checked in-process like /oauth/introspect) or a signed-in browser,
# holding only what that user may see.
class Index::ApiTest < ActionDispatch::IntegrationTest
  setup do
    @index_app = App.new(slug: "index", name: "Index", url: "https://index.app.journeybooking.eu")
    @index_app.roles.build(key: "viewer", position: 1)
    @index_app.roles.build(key: "admin", position: 2)
    @index_app.save!
    @extension = Client.create!(client_id: "index-extension", kind: "extension", app: @index_app, name: "Index browser extension",
                                redirect_uris: [ OidcHelpers::EXTENSION_REDIRECT ])
    Grant.create!(app: @index_app, subject: groups(:dk_tech), app_role: @index_app.roles.last)
    Grant.create!(app: @index_app, subject: groups(:ro_dev), app_role: @index_app.roles.first)
  end

  def extension_token(user)
    tokens = oidc_login(user, @extension, scope: "openid offline_access")
    tokens.fetch("access_token")
  end

  def api(token)
    on_index_host!
    get "/api/v1/index", headers: { "Authorization" => "Bearer #{token}" }
  end

  test "the extension's token gets the whole index, in WWW's shape, with absolute urls on INDEX_URL" do
    token = extension_token(users(:mwi))
    assert token.start_with?("tpx_index_")
    reset!
    api(token)
    assert_response :success
    assert_equal "private, no-store", response.headers["Cache-Control"]
    body = response.parsed_body

    assert_equal 1, body["version"]
    assert_equal({ "title" => "Tourpaq DK Home", "brand" => "TP DK Home", "url" => "http://index.example.com/" }, body["site"])
    assert_equal %w[Your\ apps Apps Databases], body["groups"].map { |g| g["name"] }
    assert_equal %w[everyone everyone technical], body["groups"].map { |g| g["audience"] }
    assert_equal [ "KPI" ], body["groups"].first["apps"].map { |a| a["name"] }, "IRM has an entry; the index app is left out"

    apps = body["groups"].second["apps"]
    salesview = apps.find { |a| a["name"] == "Salesview" }
    assert_equal "https://salesview.app.journeybooking.eu", salesview["url"]
    assert_equal({ "label" => "NetBird access", "tone" => "ok" }, salesview["access"])
    assert_equal [ "Booking admin" ], salesview["links"].map { |l| l["label"] }
    assert_nil salesview["page_url"]
    assert_equal "http://index.example.com/apps/salesview", salesview["details_url"]
    %w[name description status url page_url details_url address owner repo icon icon_url initials access login links].each do |key|
      assert salesview.key?(key), "WWW's field #{key} is kept"
    end

    irm = apps.find { |a| a["name"] == "IRM" }
    assert_equal [ "irm", "admin", [ "admin" ], "app" ], irm.values_at("app", "role", "roles", "visibility")

    sql = body["groups"].last["apps"].find { |a| a["name"] == "MS SQL Master - Bravo" }
    assert_equal "http://index.example.com/apps/ms-sql-master-bravo", sql["page_url"]
    assert_equal "sql-bp-we-01.tourpaq.com", sql["address"]
    assert sql.key?("login") && sql["login"].nil?, "an unset login is sent as null, not left out"

    doc = body["docs"].find { |d| d["title"] == "App deployment" }
    assert_equal "http://index.example.com/docs/deployment/deploying-a-new-app", doc["url"]
  end

  test "it holds only what the token's user may see" do
    token = extension_token(users(:alice))
    reset!
    api(token)
    body = response.parsed_body
    assert_equal [ "Apps" ], body["groups"].map { |g| g["name"] }
    assert_equal %w[IRM Salesview], body["groups"].first["apps"].map { |a| a["name"] }
    assert_equal "responder", body["groups"].first["apps"].first["role"]
  end

  test "site paths in links and icons become absolute; entries without a section are still listed" do
    index_entries(:salesview).update!(icon: "/logo.png", section: nil, links_attributes: [ { label: "Runbook", url: "/docs/runbook" } ])
    sign_in_index users(:alice)
    get "/api/v1/index"
    assert_response :success
    group = response.parsed_body["groups"].last
    assert_equal "Not yet in a group", group["name"]
    salesview = group["apps"].find { |a| a["name"] == "Salesview" }
    assert_equal "http://index.example.com/logo.png", salesview["icon_url"]
    assert_nil salesview["icon"]
    assert_includes salesview["links"].map { |l| l["url"] }, "http://index.example.com/docs/runbook"
  end

  test "the index host's session works too (a signed-in browser)" do
    sign_in_index users(:mwi)
    get "/api/v1/index"
    assert_response :success
    assert_includes response.parsed_body["groups"].map { |g| g["name"] }, "Databases"
  end

  test "no token, an unknown or foreign token, or a refresh token is 401" do
    on_index_host!
    get "/api/v1/index"
    assert_response :unauthorized
    assert_match "Bearer", response.headers["WWW-Authenticate"]
    assert_equal({ "issuer" => "http://auth.example.com", "client_id" => "index-extension", "scope" => "openid email profile offline_access" },
                 response.parsed_body["auth"], "where the extension signs in")
    api("tpx_index_#{'x' * 43}")
    assert_response :unauthorized
    assert_match 'error="invalid_token"', response.headers["WWW-Authenticate"]

    tokens = oidc_login(users(:alice), clients(:irm_extension), scope: "openid offline_access")
    reset!
    api(tokens["access_token"])
    assert_response :unauthorized, "an IRM extension token is not the index's"

    tokens = oidc_login(users(:alice), @extension, scope: "openid offline_access")
    reset!
    api(tokens["refresh_token"])
    assert_response :unauthorized
  end

  test "a revoked or expired token, a disabled user, or lost access to the index app is 401 at once" do
    token = extension_token(users(:alice))
    reset!
    api(token)
    assert_response :success

    Grant.where(app: @index_app, subject: groups(:ro_dev)).delete_all
    api(token)
    assert_response :unauthorized, "no access to the index app any more"

    Grant.create!(app: @index_app, subject: groups(:ro_dev), app_role: @index_app.roles.first)
    api(token)
    assert_response :success
    OauthToken.find_by!(token_digest: HashedToken.digest(token)).update!(expires_at: 1.minute.ago)
    api(token)
    assert_response :unauthorized

    OauthToken.find_by!(token_digest: HashedToken.digest(token)).update!(expires_at: 1.hour.from_now, revoked_at: Time.current)
    api(token)
    assert_response :unauthorized
  end

  test "a disabled extension client's tokens are refused" do
    token = extension_token(users(:alice))
    @extension.update!(disabled_at: Time.current)
    reset!
    api(token)
    assert_response :unauthorized
  end

  test "use is recorded on the token, as introspection does" do
    token = extension_token(users(:alice))
    row = OauthToken.find_by!(token_digest: HashedToken.digest(token))
    assert_nil row.last_used_at
    reset!
    api(token)
    assert row.reload.last_used_at
  end

  test "the token is never written to the log" do
    token = extension_token(users(:alice))
    reset!
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    original = Rails.logger
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    api(token)
    assert_response :success
    assert_not_includes log.string, token
  ensure
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = original if original
  end
end
