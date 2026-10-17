require "test_helper"

# The authorization API (SPECS.md §8): one user, all members, client authentication, own app only.
class Api::AccessTest < ActionDispatch::IntegrationTest
  setup do
    @secret = secret_for(clients(:irm_web))
    @auth = basic_auth("irm-web", @secret)
    on_auth_host!
  end

  test "one user with access: role, identity, sessions_valid_after, max-age 300" do
    users(:alice).sign_out_everywhere!(actor: users(:mwi))
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    assert_response :success
    assert_match(/max-age=300/, response.headers["Cache-Control"])
    assert_match(/private/, response.headers["Cache-Control"])
    body = response.parsed_body
    assert_equal({ "sub" => users(:alice).sub, "active" => true, "role" => "responder", "email" => "alice@tourpaq.com",
                   "name" => "Alice Popescu", "sessions_valid_after" => users(:alice).reload.sessions_valid_after.to_r.ceil },
                 body.except("checked_at"))
    assert_in_delta Time.current.to_i, Time.iso8601(body["checked_at"]).to_i, 2
  end

  # Apps keep their session start in whole seconds and end a session that started before sessions_valid_after: a
  # truncated value would keep a session that started in the same second as the sign out, so it is rounded up.
  test "sessions_valid_after is rounded up to the next second, in the access answer and the members list" do
    travel_to Time.utc(2026, 10, 17, 8, 31, 26.366r), with_usec: true do
      users(:alice).sign_out_everywhere!(actor: users(:mwi))
    end
    signed_out = Time.utc(2026, 10, 17, 8, 31, 27).to_i
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    assert_equal signed_out, response.parsed_body["sessions_valid_after"]
    app_session_started = Time.utc(2026, 10, 17, 8, 31, 26).to_i # the same second, before the sign out
    assert_operator app_session_started, :<, response.parsed_body["sessions_valid_after"], "an app ends that session"
    get "/api/v1/access", headers: @auth
    assert_equal signed_out, response.parsed_body["members"].detect { _1["sub"] == users(:alice).sub }["sessions_valid_after"]

    travel_to Time.utc(2026, 10, 17, 9, 0, 0), with_usec: true do
      users(:alice).sign_out_everywhere!(actor: users(:mwi))
    end
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    assert_equal Time.utc(2026, 10, 17, 9, 0, 0).to_i, response.parsed_body["sessions_valid_after"], "a whole second stays as it is"
  end

  test "active false (role null) for no access, disabled and unknown users" do
    [ users(:bob).sub, users(:dave_disabled).sub, SecureRandom.uuid ].each do |sub|
      get "/api/v1/access/#{sub}", headers: @auth
      assert_response :success
      assert_equal [ sub, false, nil, nil ], response.parsed_body.values_at("sub", "active", "role", "email")
    end
  end

  test "a client can only ask about its own app" do
    kpi = basic_auth("kpi-web", secret_for(clients(:kpi_web)))
    get "/api/v1/access/#{users(:alice).sub}", headers: kpi
    assert_equal false, response.parsed_body["active"], "alice has IRM, not KPI"
    get "/api/v1/access/#{users(:mwi).sub}", headers: kpi
    assert_equal [ true, "admin" ], response.parsed_body.values_at("active", "role")
  end

  test "lowering a role or removing access shows at the next call" do
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: app_roles(:irm_viewer))
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    assert_equal "viewer", response.parsed_body["role"]
    Grant.find_by(subject: users(:alice)).update!(app_role: nil)
    get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    assert_equal false, response.parsed_body["active"]
  end

  test "members: everybody with access, with an ETag and If-None-Match" do
    get "/api/v1/access", headers: @auth
    assert_response :success
    body = response.parsed_body
    assert_equal "irm", body["app"]
    by_email = body["members"].index_by { _1["email"] }
    assert_equal %w[alice@tourpaq.com jjr@tourpaq.com mwi@tourpaq.com], by_email.keys.sort
    assert_equal({ "sub" => users(:alice).sub, "role" => "responder", "email" => "alice@tourpaq.com", "name" => "Alice Popescu",
                   "sessions_valid_after" => nil }, by_email["alice@tourpaq.com"])
    etag = response.headers["ETag"]
    assert etag.present?

    get "/api/v1/access", headers: @auth.merge("If-None-Match" => etag)
    assert_response :not_modified

    Grant.create!(app: apps(:irm), subject: users(:bob), app_role: app_roles(:irm_viewer))
    get "/api/v1/access", headers: @auth.merge("If-None-Match" => etag)
    assert_response :success
    assert_includes response.parsed_body["members"].map { _1["email"] }, "bob@tourpaq.com"
    assert_not_equal etag, response.headers["ETag"]
  end

  test "client authentication: web clients only, Basic, refused for a disabled app or client" do
    get "/api/v1/access"
    assert_response :unauthorized
    get "/api/v1/access", headers: basic_auth("irm-web", "tpcs_wrong")
    assert_response :unauthorized
    get "/api/v1/access", headers: basic_auth("irm-extension", "")
    assert_response :unauthorized

    apps(:irm).update!(disabled_at: Time.current)
    get "/api/v1/access", headers: @auth
    assert_response :unauthorized
    apps(:irm).update!(disabled_at: nil)
    clients(:irm_web).update!(disabled_at: Time.current)
    get "/api/v1/access", headers: @auth
    assert_response :unauthorized
  end

  test "an expired secret is refused; the other of two secrets still works" do
    expiring = clients(:irm_web).generate_secret!(expires_at: 1.day.from_now, created_by: users(:mwi))
    get "/api/v1/access", headers: basic_auth("irm-web", expiring)
    assert_response :success
    travel 2.days
    get "/api/v1/access", headers: basic_auth("irm-web", expiring)
    assert_response :unauthorized
    get "/api/v1/access", headers: @auth
    assert_response :success
  end

  test "counted per client and day, not audited" do
    assert_no_difference -> { AuditEvent.count } do
      get "/api/v1/access", headers: @auth
      get "/api/v1/access/#{users(:alice).sub}", headers: @auth
    end
    assert_equal 2, UsageCount.find_by(client: clients(:irm_web), kind: "access").count
  end

  test "rate limited per client" do
    600.times { get "/api/v1/access/x", headers: @auth }
    get "/api/v1/access/x", headers: @auth
    assert_response :too_many_requests
  end

  test "the API does not exist on the admin host" do
    on_admin_host!
    get "/api/v1/access", headers: @auth
    assert_response :not_found
  end
end
