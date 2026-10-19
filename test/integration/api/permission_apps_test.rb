require "test_helper"

# The protocol for a permission app (SPECS.md §23.2, §23.3, §7.3, §8, §9.2): role list and permissions claims,
# roles and permissions in the access API and introspection, the members ETag, the catalogue push, per-app scopes.
class Api::PermissionAppsTest < ActionDispatch::IntegrationTest
  setup do
    @dash = create_dashboard_app
    @client = Client.find_by!(client_id: "home-web")
    @secret = secret_for(@client)
    @auth = basic_auth("home-web", @secret)
    grant_dashboard(users(:alice), "Support")
    grant_dashboard(groups(:ro_dev), "Finance readers")
    on_auth_host!
  end

  def alice_permissions = %w[management:finance:view module:customers:view module:tasks:view]

  test "ID token and userinfo: the role claim is a list, the permissions claim the sorted union" do
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "home-web", nonce: tokens["nonce"])
    assert_equal [ "Finance readers", "Support" ], claims["home_roles"]
    assert_equal alice_permissions, claims["home_permissions"]
    assert_nil claims["dashboard_role"]

    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{tokens['access_token']}" }
    assert_equal [ [ "Finance readers", "Support" ], alice_permissions ], response.parsed_body.values_at("home_roles", "home_permissions")
  end

  test "* is passed through as is" do
    grant_dashboard(users(:mwi), "Administrators")
    tokens = oidc_login(users(:mwi), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "home-web")
    assert_equal [ "Administrators" ], claims["home_roles"]
    assert_equal [ "*" ], claims["home_permissions"]
  end

  test "the claims never replace a standard claim" do
    @dash.update_columns(role_claim: "email")
    tokens = oidc_login(users(:alice), @client, secret: @secret)
    claims = verify_id_token(tokens["id_token"], aud: "home-web")
    assert_equal "alice@tourpaq.com", claims["email"]
    assert_equal alice_permissions, claims["home_permissions"]
  end

  test "no roles means no access at authorize" do
    sign_in_as users(:bob)
    get authorize_path_for(@client)
    assert_response :forbidden
    assert_select "h1", /access/i
  end

  test "access API: roles and permissions, role null; empty lists without access" do
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    body = response.parsed_body
    assert_equal [ true, nil, [ "Finance readers", "Support" ], alice_permissions ], body.values_at("active", "role", "roles", "permissions")

    get "/api/v1/access/#{users(:bob).sub}", headers: @auth
    assert_equal [ false, nil, [], [] ], response.parsed_body.values_at("active", "role", "roles", "permissions")

    get "/api/v1/access/#{users(:alice).sub}", headers: basic_auth("irm-web", secret_for(clients(:irm_web)))
    assert_not response.parsed_body.key?("roles"), "single-role apps are unchanged"
  end

  test "members: roles and permissions per member; the ETag changes when a role's permissions do" do
    get "/api/v1/access", headers: @auth
    alice = response.parsed_body["members"].detect { _1["email"] == "alice@tourpaq.com" }
    assert_equal({ "sub" => users(:alice).sub, "role" => nil, "roles" => [ "Finance readers", "Support" ],
                   "permissions" => alice_permissions, "email" => "alice@tourpaq.com", "name" => "Alice Popescu",
                   "sessions_valid_after" => nil }, alice)
    etag = response.headers["ETag"]
    get "/api/v1/access", headers: @auth.merge("If-None-Match" => etag)
    assert_response :not_modified

    @dash.role("Support").update!(permissions: %w[module:customers:view])
    get "/api/v1/access", headers: @auth.merge("If-None-Match" => etag)
    assert_response :success
    assert_not_equal etag, response.headers["ETag"]
  end

  test "introspection: roles, permissions and the token's scope from the app's list" do
    token = PersonalToken.issue!(user: users(:alice), app: @dash, name: "Paperclip", scope: "all")
    answer = introspect(token, client_id: "home-web", secret: @secret)
    assert_equal [ true, "all", nil, [ "Finance readers", "Support" ], alice_permissions ],
                 answer.values_at("active", "scope", "role", "roles", "permissions")
    assert token.start_with?("tpa_home_")

    irm_token = PersonalToken.issue!(user: users(:alice), app: apps(:irm), name: "IRM", scope: "read_write")
    answer = introspect(irm_token, secret: secret_for(clients(:irm_web)))
    assert_equal [ "read_write", "responder" ], answer.values_at("scope", "role")
    assert_not answer.key?("permissions")
  end

  test "extension tokens get the app's highest scope" do
    extension = Client.create!(app: @dash, client_id: "dashboard-extension", kind: "extension", name: "Dashboard extension",
                               redirect_uris: [ OidcHelpers::EXTENSION_REDIRECT ])
    tokens = oidc_login(users(:alice), extension, scope: "openid offline_access")
    answer = introspect(tokens["access_token"], client_id: "home-web", secret: @secret)
    assert_equal [ true, "extension", "all" ], answer.values_at("active", "token_type", "scope")
  end

  test "catalogue push: replaces, reports added/removed/unknown, audited only when it changed" do
    @dash.role("Support").update!(permissions: %w[module:customers:view module:tasks:view])
    body = { permissions: [ { key: "module:customers:view", label: "Customers", group: "Modules" },
                            { key: "module:invoices:view", label: "Invoices", group: "Modules" } ] }
    put "/api/v1/catalogue", params: body.to_json, headers: @auth.merge("Content-Type" => "application/json")
    assert_response :success
    answer = response.parsed_body
    assert_equal [ "home", 2, [ "module:invoices:view" ] ], answer.values_at("app", "count", "added")
    assert_includes answer["removed"], "module:tasks:view"
    assert_includes answer["unknown"], { "role" => "Support", "permissions" => [ "module:tasks:view" ] }
    assert_equal %w[module:customers:view module:invoices:view], @dash.reload.catalogue_keys
    event = AuditEvent.where(action: "app.catalogue_pushed").last
    assert_equal [ @dash, nil, "api" ], [ event.subject, event.actor, event.channel ]
    assert_equal [ "module:invoices:view" ], event.data["added"]

    assert_no_difference -> { AuditEvent.where(action: "app.catalogue_pushed").count } do
      put "/api/v1/catalogue", params: body.to_json, headers: @auth.merge("Content-Type" => "application/json")
      assert_response :success
    end
  end

  test "catalogue push: refused without client auth, bad bodies change nothing" do
    put "/api/v1/catalogue", params: { permissions: [] }.to_json, headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
    before = @dash.catalogue_keys
    [ "not json", { permissions: "x" }.to_json, { other: [] }.to_json, { permissions: [ { key: "bad key" } ] }.to_json,
      { permissions: [ { key: "a:b" }, { key: "a:b" } ] }.to_json ].each do |payload|
      put "/api/v1/catalogue", params: payload, headers: @auth.merge("Content-Type" => "application/json")
      assert_response :bad_request, payload
      assert_equal "invalid_request", response.parsed_body["error"]
    end
    put "/api/v1/catalogue", params: { permissions: [ { key: "a:b", label: "x" * 200 } ] * 6000 }.to_json,
                             headers: @auth.merge("Content-Type" => "application/json")
    assert_response :bad_request
    assert_match "larger than", response.parsed_body["error_description"]
    assert_equal before, @dash.reload.catalogue_keys
  end

  test "a client pushes only its own app's catalogue" do
    put "/api/v1/catalogue", params: { permissions: [ { key: "irm:x:view" } ] }.to_json,
                             headers: basic_auth("irm-web", secret_for(clients(:irm_web))).merge("Content-Type" => "application/json")
    assert_response :success
    assert_equal [ "irm:x:view" ], apps(:irm).reload.catalogue_keys
    assert_not_includes @dash.reload.catalogue_keys, "irm:x:view"
  end
end
