require "test_helper"

# The index host's front page (SPECS.md §11.1, §24.3): WWW's front page for the signed-in viewer, with their apps.
class IndexHomeTest < ActionDispatch::IntegrationTest
  test "cards sections as cards, the IRM entry with the viewer's role, tiles into the table sections and docs" do
    sign_in_index users(:mwi)
    assert_response :success
    assert_equal index_host, URI(request.url).host
    assert_select ".ix-hero h1", "Tourpaq DK Home"
    assert_select ".ix-card .ix-card-name", text: "Salesview"
    assert_select ".ix-card .ix-card-name", text: "IRM"
    assert_select ".ix-card .ix-card-role .badge.role-admin", "admin"
    assert_select ".ix-card .ix-card-name", text: "MS SQL Master - Bravo", count: 0
    assert_select ".ix-tile[href=?]", "/groups/databases"
    assert_select ".ix-tile[href=?]", "/docs/deployment/deploying-a-new-app"
    assert_select ".sidebar .nav-section", text: "Technical"
    assert_select ".sidebar a.ix-nav-item[href='/groups/databases']"
  end

  test "RO Dev sees neither the technical section nor its tile, but the IRM entry with their role and where it comes from" do
    sign_in_index users(:alice)
    assert_select ".ix-card .ix-card-name", text: "IRM"
    assert_select ".ix-card .ix-card-role .badge.role-responder", "responder"
    assert_select ".ix-tile[href=?]", "/groups/databases", count: 0
    assert_select ".sidebar a[href='/groups/databases']", 0
    assert_select ".sidebar .nav-section", text: "Technical", count: 0
  end

  test "Your apps holds every app with access, an app with an entry as that entry's card, not repeated below" do
    Grant.create!(app: apps(:kpi), subject: users(:alice), app_role: app_roles(:kpi_viewer))
    sign_in_index users(:alice)
    your_apps = css_select("#your-apps + .ix-grid .ix-card-name").map { _1.text.strip }
    assert_equal [ "IRM", "KPI" ], your_apps
    assert_select ".ix-app-card", 1, "KPI has no entry: the app's own card"
    assert_select ".ix-app-card .ix-card-name a[href='https://kpi.app.journeybooking.eu']", "KPI"
    assert_select ".ix-app-card .badge.role-viewer", "viewer"
    assert_select ".ix-app-card .ix-card-role", /direct/
    assert_select "#apps + .ix-grid .ix-card-name", text: "IRM", count: 0
    assert_select "#apps + .ix-grid .ix-card-name", text: "Salesview"
  end

  test "a customer (in no staff group) sees only their apps: no sections, tiles or docs" do
    Grant.create!(app: apps(:irm), subject: users(:carol), app_role: app_roles(:irm_viewer))
    sign_in_index users(:carol)
    assert_equal [ "IRM" ], css_select(".ix-card-name").map { _1.text.strip }
    assert_select ".ix-app-card", 1, "IRM's entry is in Apps (for all staff), so the app's own card"
    assert_select ".ix-tile", 0
    assert_select ".sidebar a[href^='/groups/']", 0
    assert_select ".sidebar a[href^='/docs/']", 0
    get "/groups/apps"
    assert_response :not_found
    get "/apps/salesview"
    assert_response :not_found
  end

  test "a known icon name is drawn as SVG for an app, anything else as text or initials" do
    index_entries(:irm).destroy!
    apps(:irm).update!(icon: "bell")
    apps(:kpi).update!(icon: nil)
    sign_in_index users(:mwi)
    assert_select ".ix-app-card .ix-icon svg", 1
    assert_select ".ix-app-card .ix-icon-initials", "K"
  end

  test "apps hidden from the launcher or disabled get no card, and the index app itself never" do
    index_entries(:irm).destroy!
    apps(:kpi).update!(show_in_launcher: false)
    index_app = App.new(slug: "index", name: "Index", url: "https://index.app.journeybooking.eu")
    index_app.roles.build(key: "viewer", position: 1)
    index_app.save!
    Grant.create!(app: index_app, subject: groups(:dk_tech), app_role: index_app.roles.first)
    sign_in_index users(:mwi)
    assert_select ".ix-app-card .ix-card-name", "IRM"
    apps(:irm).update!(disabled_at: Time.current)
    get "/"
    assert_select ".ix-app-card", 0
  end

  test "a user with nothing at all sees that" do
    Index::Entry.delete_all
    Grant.create!(app: apps(:kpi), subject: users(:carol), app_role: app_roles(:kpi_viewer))
    sign_in_index users(:carol)
    assert_select ".ix-app-card", 1
    Grant.where(subject: users(:carol)).delete_all
    Grant.create!(app: apps(:kpi), subject: groups(:ro_devops), app_role: app_roles(:kpi_viewer))
    GroupMembership.create!(group: groups(:ro_devops), user: users(:carol))
    apps(:kpi).update!(show_in_launcher: false)
    get "/"
    assert_select ".empty", /Nothing has been given to you yet/
  end

  test "a pending user is sent to the auth host's waiting page, which sends them on once they have access" do
    sign_in_as users(:bob)
    assert_redirected_to "/"
    follow_redirect!
    assert_redirected_to "/waiting", "the auth host's / knows they have nothing yet"
    follow_redirect!
    assert_select "h1", "Waiting for access"
    assert_match "An admin has been told", response.body

    sign_in_index users(:bob), sign_in: false
    assert_redirected_to AuthHosts.waiting_url
    assert Session.index_host.where(user: users(:bob)).active.exists?, "signed in on the index host all the same"
    get "/profile"
    assert_redirected_to AuthHosts.waiting_url
    get "/search.json"
    assert_redirected_to AuthHosts.waiting_url

    Grant.create!(app: apps(:kpi), subject: users(:bob), app_role: app_roles(:kpi_viewer))
    on_auth_host!
    get "/waiting"
    assert_redirected_to "http://index.example.com/"
    on_index_host!
    get "/"
    assert_select ".ix-app-card .ix-card-name", "KPI"
  end

  test "admins get a link to the admin host" do
    sign_in_index users(:mwi)
    assert_select "a.admin-link[href='http://admin.example.com/']", "Admin"
    assert_select "a.nav-item[href='http://admin.example.com/']", "Admin"
  end

  test "others get no admin link" do
    sign_in_index users(:alice)
    assert_select "a.nav-item", { text: "Admin", count: 0 }
    assert_select "a.admin-link", 0
  end

  test "personal tokens expiring within 7 days are a reminder" do
    soon = create_personal_token(users(:alice), apps(:irm), name: "Old laptop", lifetime_days: 30)
    soon.update_columns(expires_at: 3.days.from_now)
    create_personal_token(users(:alice), apps(:irm), name: "New laptop")
    sign_in_index users(:alice)
    assert_select ".reminder", 1
    assert_select ".reminder li", 1
    assert_select ".reminder li", /Old laptop for IRM/
    assert_select ".reminder a[href='/tokens']"
  end

  test "no reminder without expiring tokens" do
    sign_in_index users(:alice)
    assert_select ".reminder", 0
  end

  test "the index requires sign-in through the auth host" do
    on_index_host!
    get "/"
    location = URI(response.location)
    assert_equal [ auth_host, "/oauth/authorize" ], [ location.host, location.path ]
    assert_equal [ "index", AuthHosts.index_callback_url ], URI.decode_www_form(location.query).to_h.values_at("client_id", "redirect_uri")
  end

  test "the auth host's / sends a signed-in user to the index host, anybody else to sign in" do
    get "/"
    assert_redirected_to "/sign_in"
    sign_in_as users(:alice)
    get "/"
    assert_redirected_to "http://index.example.com/"
  end

  test "the index's pages are only on the index host" do
    %w[/search /search.json /groups/apps /apps/salesview /docs/deployment/deploying-a-new-app /api/v1/index].each do |path|
      on_auth_host!
      get path
      assert_response :not_found, "#{path} on the auth host"
      on_internal_host!
      get path
      assert_response :not_found, "#{path} on the back-channel host"
    end
  end
end
