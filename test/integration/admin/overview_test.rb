require "test_helper"

# Admin: dashboard, Entra secret banner, tokens overview, access matrix, audit log (SPECS.md §9, §11.2, §12, §14).
class Admin::OverviewTest < ActionDispatch::IntegrationTest
  setup { sign_in_admin users(:mwi) }

  test "the dashboard lists pending users and the sidebar has every section" do
    get "/"
    assert_response :success
    assert_select "td a", "Bob Ionescu"
    %w[/users /groups /apps /access /tokens /audit].each { assert_select "a.nav-item[href='#{_1}']" }
  end

  test "the Entra client secret banner shows from 30 days before it expires" do
    # Days are counted on the Copenhagen calendar, which is a day ahead of UTC late in the evening.
    today = Time.current.in_time_zone(ApplicationHelper::DEFAULT_TIME_ZONE).to_date
    with_auth_config(entra_client_secret_expires_on: today + 40) do
      get "/"
      assert_select ".banner", 0
    end
    with_auth_config(entra_client_secret_expires_on: today + 12) do
      get "/users"
      assert_select ".banner.banner-warn", /expires in 12 days/
    end
    with_auth_config(entra_client_secret_expires_on: today - 1) do
      get "/"
      assert_select ".banner.banner-bad", /expired/
    end
    with_auth_config(entra_client_secret_expires_on: nil) do
      get "/"
      assert_select ".banner", 0
    end
  end

  test "tokens: everyone's, unused for 90 days flagged, revoke" do
    fresh = create_personal_token(users(:alice), apps(:irm), name: "Fresh")
    stale = create_personal_token(users(:mwi), apps(:kpi), name: "Stale")
    stale.update_columns(created_at: 100.days.ago, last_used_at: 95.days.ago)
    get "/tokens"
    assert_response :success
    assert_select "td", "Fresh"
    assert_select "td", "Stale"
    assert_select ".pill", { text: "unused 90 days", count: 1 }

    get "/tokens", params: { state: "unused" }
    assert_select "td", { text: "Fresh", count: 0 }
    get "/tokens", params: { app_id: apps(:irm).id }
    assert_select "td", { text: "Stale", count: 0 }

    delete "/tokens/#{fresh.id}"
    assert_redirected_to "/tokens"
    assert fresh.reload.revoked?
    assert_equal users(:mwi), fresh.revoked_by
    event = audit("token.revoked")
    assert_equal [ users(:mwi), fresh ], [ event.actor, event.subject ]
    get "/tokens", params: { state: "revoked" }
    assert_select "td", "Fresh"
  end

  test "the access matrix shows effective roles with their source" do
    get "/access"
    assert_response :success
    assert_select "table.matrix thead th", 3 # User, IRM, KPI
    row = css_select("table.matrix tbody tr").find { _1.text.include?("alice@tourpaq.com") }
    assert_match "responder", row.text
    assert_match "RO Dev", row.text
    assert_select "table.matrix tbody tr", User.active.count
    get "/access", params: { with_access: "1" }
    assert_select "table.matrix tbody tr", 3 # mwi, jjr, alice
  end

  test "the access matrix as CSV, audited" do
    users(:alice).update!(name: "=cmd|' /C calc'!A0")
    get "/access.csv"
    assert_response :success
    assert_equal "text/csv; charset=utf-8", response.content_type
    assert_match(/attachment; filename="access-matrix-\d{4}-\d{2}-\d{2}\.csv"/, response.headers["Content-Disposition"])
    lines = response.body.split("\r\n")
    assert_equal "email,name,irm,irm source,kpi,kpi source", lines.first
    assert_includes lines, "alice@tourpaq.com,'=cmd|' /C calc'!A0,responder,RO Dev,,"
    assert_includes lines, "mwi@tourpaq.com,Mogens Winther,admin,DK Tech,admin,DK Tech"
    assert_includes lines, "bob@tourpaq.com,Bob Ionescu,,,,"
    assert_not lines.any? { _1.start_with?("dave@") }, "disabled users are left out"
    assert audit("access.exported")
  end

  test "the audit log filters by user, app and action" do
    post "/grants", params: { app_id: apps(:kpi).id, subject_type: "User", subject_id: users(:bob).id, role: "viewer" }
    post "/users/#{users(:alice).id}/make_admin"
    get "/audit"
    assert_response :success
    assert_select "td.mono a", "grant.created"
    assert_select "td.mono a", "user.admin_granted"

    get "/audit", params: { event: "grant." }
    assert_select "td.mono a", { text: "user.admin_granted", count: 0 }
    assert_select "td.mono a", "grant.created"

    get "/audit", params: { app_id: apps(:kpi).id }
    assert_select "td.mono a", "grant.created"
    assert_select "td.mono a", { text: "user.admin_granted", count: 0 }

    get "/audit", params: { user_id: users(:alice).id }
    assert_select "td.mono a", "user.admin_granted"
    assert_select "td.mono a", { text: "grant.created", count: 0 }
  end

  test "the audit log pages by id" do
    105.times { AuditEvent.record("test.event", actor: users(:mwi)) }
    get "/audit", params: { event: "test." }
    assert_select "tbody tr", 100
    older = css_select("a").find { _1.text == "Older" }
    assert older
    get older["href"]
    assert_select "tbody tr", 5
  end
end
