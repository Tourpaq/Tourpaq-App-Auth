require "test_helper"

# The admin host's own session and checks (SPECS.md §11.2, §22).
class AdminAuthenticationTest < ActionDispatch::IntegrationTest
  test "without an admin session the admin host starts the admin sign-in" do
    on_admin_host!
    get "/"
    assert_admin_sign_in_started
  end

  test "an admin signs in and gets the admin UI with its own host-only cookie" do
    sign_in_admin users(:mwi)
    assert_redirected_to "/"
    assert_match(/admin_session=/, Array(response.headers["Set-Cookie"]).join)
    follow_redirect!
    assert_response :success
    assert_select ".brand", /Tourpaq Admin/
    session = Session.last
    assert_equal [ "admin", users(:mwi) ], [ session.kind, session.user ]
    assert_equal({ "session_id" => session.id, "kind" => "admin" }, AuditEvent.last.data)
  end

  test "the admin goes back to the page they asked for" do
    on_admin_host!
    get "/?filter=pending"
    sign_in_admin users(:mwi)
    assert_redirected_to "/?filter=pending"
  end

  test "an auth session does not sign in to the admin host" do
    sign_in_as users(:mwi)
    on_admin_host!
    get "/"
    assert_admin_sign_in_started
  end

  test "a non-admin sees 'not an admin', audited, and gets no admin session" do
    sign_in_admin users(:alice)
    assert_response :forbidden
    assert_select "h1", "Not an admin"
    assert_equal [ "admin.denied", users(:alice) ], [ AuditEvent.last.action, AuditEvent.last.actor ]
    assert_not Session.admin.exists?(user: users(:alice))
  end

  test "a demoted admin is out at the next request" do
    sign_in_admin users(:jjr)
    get "/"
    assert_response :success
    users(:jjr).update_columns(admin: false) # e.g. by another admin, without ending sessions
    get "/"
    assert_response :forbidden
    assert_select "h1", "Not an admin"
    assert_equal "not_admin", Session.admin.find_by(user: users(:jjr)).end_reason
    get "/"
    assert_admin_sign_in_started
  end

  test "a disabled admin is out at the next request" do
    sign_in_admin users(:jjr)
    users(:jjr).disable!(actor: users(:mwi))
    get "/"
    assert_admin_sign_in_started
  end

  test "the admin session ends after 2 idle hours" do
    sign_in_admin users(:mwi)
    travel 2.hours + 1.minute
    get "/"
    assert_admin_sign_in_started
    assert_equal "idle", Session.admin.last.end_reason
  end

  test "the admin session ends 12 hours after the Entra sign-in, however active" do
    sign_in_admin users(:mwi)
    11.times do
      travel 1.hour
      get "/"
      assert_response :success
    end
    travel 1.hour + 1.minute
    get "/"
    assert_admin_sign_in_started
    assert_equal "expired", Session.admin.last.end_reason
  end

  test "ADMIN_ALLOWED_CIDRS refuses other addresses, even for an admin" do
    with_auth_config(admin_allowed_cidrs: [ IPAddr.new("100.64.0.0/10") ]) do
      on_admin_host!
      get "/", env: { "REMOTE_ADDR" => "203.0.113.5" }
      assert_response :forbidden
      assert_equal "network", AuditEvent.last.data["reason"]

      post "/dev/admin_sign_in", params: { email: "mwi@tourpaq.com" }, env: { "REMOTE_ADDR" => "203.0.113.5" }
      assert_response :forbidden

      post "/dev/admin_sign_in", params: { email: "mwi@tourpaq.com" }, env: { "REMOTE_ADDR" => "100.64.1.2" }
      assert_redirected_to "/"
      get "/", env: { "REMOTE_ADDR" => "100.64.1.2" }
      assert_response :success
    end
  end

  test "X-Forwarded-For counts only from a trusted proxy" do
    with_auth_config(admin_allowed_cidrs: [ IPAddr.new("100.64.0.0/10") ]) do
      on_admin_host!
      # From the internet, a forged header does not help.
      get "/", env: { "REMOTE_ADDR" => "203.0.113.5", "HTTP_X_FORWARDED_FOR" => "100.64.1.2" }
      assert_response :forbidden
      # Through the proxy (a private address), the client address it sets counts.
      get "/", env: { "REMOTE_ADDR" => "172.18.0.2", "HTTP_X_FORWARDED_FOR" => "100.64.1.2" }
      assert_admin_sign_in_started
      get "/", env: { "REMOTE_ADDR" => "172.18.0.2", "HTTP_X_FORWARDED_FOR" => "203.0.113.5" }
      assert_response :forbidden
    end
  end

  test "a direct client cannot claim another host through X-Forwarded-Host" do
    on_auth_host!
    get "/", env: { "REMOTE_ADDR" => "203.0.113.5", "HTTP_X_FORWARDED_HOST" => admin_host }
    assert_redirected_to "http://auth.example.com/sign_in"
  end

  test "sign out ends only the admin session" do
    sign_in_as users(:mwi)
    home = Session.home.last
    sign_in_admin users(:mwi)
    delete "/session"
    assert_response :success
    assert_equal "signed_out", Session.admin.last.end_reason
    assert home.reload.active?
    get "/"
    assert_admin_sign_in_started
  end
end
