require "test_helper"

# Admin: apps, roles, clients, secrets, members (SPECS.md §5.1, §7.4, §11.2).
class Admin::AppsTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  test "list, page and members with effective roles and their source" do
    get "/apps"
    assert_response :success
    assert_select "td.wrap", "viewer < responder < editor < admin"
    get "/apps/#{apps(:irm).id}"
    assert_response :success
    assert_select "h1", /IRM/
    assert_select "td.mono a", "irm-web"
    get "/apps/#{apps(:irm).id}/members"
    assert_response :success
    rows = css_select("tbody tr").map { |tr| tr.css("td").map { _1.text.strip } }
    assert_includes rows, [ "Alice Popescu", "alice@tourpaq.com", "responder", "group RO Dev" ]
    assert_includes rows, [ "Mogens Winther", "mwi@tourpaq.com", "admin", "group DK Tech" ]
    assert_not rows.any? { _1.first == "Dave" }, "disabled users have no access"
  end

  test "create an app with its roles" do
    get "/apps/new"
    assert_response :success
    post "/apps", params: { app: { slug: "azure-cost2", name: "Azure Cost 2", url: "https://ac.example.com", icon: "cost",
                                   show_in_launcher: "1", role_list: "viewer\nadmin" } }
    app = App.find_by!(slug: "azure-cost2")
    assert_redirected_to "/apps/#{app.id}"
    assert_equal %w[viewer admin], app.role_keys
    assert_equal "azure_cost2_role", app.role_claim
    assert_equal %w[viewer admin], audit("app.created").data["roles"]
  end

  test "an app needs a valid slug and at least one role" do
    post "/apps", params: { app: { slug: "Bad Slug", name: "X", role_list: "" } }
    assert_response :unprocessable_entity
    assert_select ".errors li", /Slug/
    assert_select ".errors li", /at least one role/
  end

  test "edit an app, disable and enable it; the slug never changes" do
    get "/apps/#{apps(:kpi).id}/edit"
    assert_response :success
    patch "/apps/#{apps(:kpi).id}", params: { app: { name: "KPI Reports", slug: "other", disabled: "1" } }
    assert_redirected_to "/apps/#{apps(:kpi).id}"
    app = apps(:kpi).reload
    assert_equal [ "KPI Reports", "kpi" ], [ app.name, app.slug ]
    assert app.disabled?
    assert_equal({ "changes" => { "name" => "KPI Reports" } }, audit("app.updated").data)
    assert audit("app.disabled")
    patch "/apps/#{apps(:kpi).id}", params: { app: { name: "KPI Reports", disabled: "0" } }
    assert apps(:kpi).reload.active?
    assert audit("app.enabled")
  end

  test "roles: add, describe, remove an unused one; a used one and the last one stay" do
    app = apps(:kpi)
    post "/apps/#{app.id}/roles", params: { role: { key: "owner", description: "Owns it" } }
    assert_redirected_to "/apps/#{app.id}"
    assert_equal %w[viewer editor admin owner], app.reload.role_keys
    assert_equal "owner", audit("app.role_added").data["key"]

    post "/apps/#{app.id}/roles", params: { role: { key: "Bad Key!" } }
    assert_match "lowercase", flash[:alert]

    role = app.role("owner")
    patch "/apps/#{app.id}/roles/#{role.id}", params: { role: { description: "Owns the app" } }
    assert_equal "Owns the app", role.reload.description
    assert audit("app.role_changed")

    delete "/apps/#{app.id}/roles/#{role.id}"
    assert_not AppRole.exists?(role.id)
    assert_equal "owner", audit("app.role_removed").data["key"]

    delete "/apps/#{app.id}/roles/#{app_roles(:kpi_admin).id}"
    assert_match "used by 1 grant", flash[:alert]
    assert AppRole.exists?(app_roles(:kpi_admin).id)

    lone = App.create!(slug: "lone", name: "Lone", roles: [ AppRole.new(key: "viewer", position: 1) ])
    delete "/apps/#{lone.id}/roles/#{lone.roles.first.id}"
    assert_match "at least one role", flash[:alert]
  end

  test "reordering roles previews whose effective role changes, then saves" do
    # Alice: responder from RO Dev and editor from RO DevOps → editor (the highest).
    GroupMembership.create!(group: groups(:ro_devops), user: users(:alice))
    Grant.create!(app: apps(:irm), subject: groups(:ro_devops), app_role: app_roles(:irm_editor))
    assert_equal "editor", EffectiveRole.for(users(:alice), apps(:irm)).role_key
    new_order = %w[viewer editor responder admin]

    get "/apps/#{apps(:irm).id}/roles/reorder", params: { keys: new_order }
    assert_response :success
    assert_select ".flash-alert", /1 user's effective role changes/
    assert_select "tbody tr", 1
    assert_select "tbody td a", "Alice Popescu"
    assert_equal %w[viewer responder editor admin], apps(:irm).reload.role_keys, "the preview saves nothing"
    assert_equal "editor", EffectiveRole.for(users(:alice), apps(:irm)).role_key

    patch "/apps/#{apps(:irm).id}/roles/reorder", params: { keys: new_order }
    assert_redirected_to "/apps/#{apps(:irm).id}"
    assert_equal new_order, apps(:irm).reload.role_keys
    assert_equal "responder", EffectiveRole.for(users(:alice), apps(:irm)).role_key
    event = audit("app.roles_reordered")
    assert_equal new_order, event.data["after"]
    assert_equal [ { "user_id" => users(:alice).id, "email" => "alice@tourpaq.com", "before" => "editor", "after" => "responder" } ], event.data["users"]
  end

  test "a reorder that changes nobody says so, and a bad order is refused" do
    get "/apps/#{apps(:irm).id}/roles/reorder", params: { keys: %w[responder viewer editor admin] }
    assert_select ".flash-notice", /Nobody's effective role changes/
    get "/apps/#{apps(:irm).id}/roles/reorder", params: { keys: %w[viewer admin] }
    assert_redirected_to "/apps/#{apps(:irm).id}"
    patch "/apps/#{apps(:irm).id}/roles/reorder", params: { keys: %w[viewer viewer editor admin] }
    assert_match "every role", flash[:alert]
  end

  test "clients: create web and extension clients with exact redirect URIs, edit and disable" do
    get "/apps/#{apps(:kpi).id}/clients/new"
    assert_response :success
    post "/apps/#{apps(:kpi).id}/clients", params: { client: { client_id: "kpi-extension", kind: "extension", name: "KPI ext",
                                                              redirect_uris: "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/" } }
    client = Client.find_by!(client_id: "kpi-extension")
    assert_redirected_to "/apps/#{apps(:kpi).id}/clients/#{client.id}"
    assert_equal [ "https://abcdefghijklmnopabcdefghijklmnop.chromiumapp.org/" ], client.redirect_uris
    assert_equal "extension", audit("client.created").data["kind"]

    post "/apps/#{apps(:kpi).id}/clients", params: { client: { client_id: "kpi-two", kind: "web", redirect_uris: "https://*.example.com/cb" } }
    assert_response :unprocessable_entity
    post "/apps/#{apps(:kpi).id}/clients", params: { client: { client_id: "kpi-three", kind: "internal" } }
    assert_response :unprocessable_entity

    get "/apps/#{apps(:irm).id}/clients/#{clients(:irm_web).id}/edit"
    assert_response :success
    patch "/apps/#{apps(:irm).id}/clients/#{clients(:irm_web).id}",
          params: { client: { name: "IRM", redirect_uris: "https://irm.app.journeybooking.eu/sso/callback\n", disabled: "1" } }
    assert_equal [ "https://irm.app.journeybooking.eu/sso/callback" ], clients(:irm_web).reload.redirect_uris
    assert clients(:irm_web).disabled_at
    assert audit("client.updated")
    assert audit("client.disabled")
  end

  test "secrets: shown once, two at most, rotate and delete, audited" do
    path = "/apps/#{apps(:irm).id}/clients/#{clients(:irm_web).id}"
    get path
    assert_select ".empty", /No secret yet/

    post "#{path}/secrets", params: { expires_in_days: "365" }
    assert_response :success
    plain = css_select("input[data-copy-target='source']").first["value"]
    assert_match(/\Atpcs_[A-Za-z0-9_-]{43}\z/, plain)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal clients(:irm_web), Client.authenticate("irm-web", plain)
    assert_not ClientSecret.exists?(secret_digest: plain), "only the digest is stored"
    assert audit("client.secret_created")

    get path
    assert_not_includes response.body, plain, "never shown again"
    assert_select "td.mono", /\Atpcs_/

    post "#{path}/secrets", params: { expires_in_days: "never" }
    assert_response :success
    post "#{path}/secrets"
    assert_redirected_to path
    assert_match "already has 2 active secrets", flash[:alert]

    old = clients(:irm_web).client_secrets.order(:id).first
    delete "#{path}/secrets/#{old.id}"
    assert_redirected_to path
    assert_not ClientSecret.exists?(old.id)
    assert_nil Client.authenticate("irm-web", plain)
    assert_equal old.hint, audit("client.secret_deleted").data["hint"]
  end

  test "secrets expiring within 30 days are flagged on the client and the dashboard" do
    clients(:irm_web).generate_secret!(expires_at: 10.days.from_now, created_by: users(:mwi))
    get "/apps/#{apps(:irm).id}/clients/#{clients(:irm_web).id}"
    assert_select ".pill-warn", /expires in 10 days/
    get "/apps/#{apps(:irm).id}"
    assert_select ".pill-warn", "expiring"
    get "/"
    assert_select "h2", "Client secrets expiring"
  end

  test "extension clients have no secrets" do
    post "/apps/#{apps(:irm).id}/clients/#{clients(:irm_extension).id}/secrets"
    assert_redirected_to "/apps/#{apps(:irm).id}/clients/#{clients(:irm_extension).id}"
    assert_match "only web clients", flash[:alert]
  end
end
