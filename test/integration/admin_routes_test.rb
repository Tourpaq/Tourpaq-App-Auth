require "test_helper"

# Every admin route is a 404 on the auth and index hosts (SPECS.md §11.2, §22, §24.1): it does not exist there,
# it is not a redirect, and a signed-in admin's auth or index session changes nothing.
class AdminRoutesTest < ActionDispatch::IntegrationTest
  def admin_routes
    Rails.application.routes.routes.select { _1.defaults[:controller].to_s.start_with?("admin/") }
  end

  # Paths the other hosts also have, with their own controller (the root, DELETE /session, /sso/callback, the
  # user's own /tokens): those answer there, from that host's controller.
  def home_too?(route)
    @home_routes ||= Rails.application.routes.routes.reject { _1.defaults[:controller].to_s.start_with?("admin/") }
                                                    .map { [ _1.verb, _1.path.spec.to_s ] }.to_set
    @home_routes.include?([ route.verb, route.path.spec.to_s ])
  end

  def concrete_path(route)
    route.path.spec.to_s.sub("(.:format)", "").gsub(/:\w+/, "1")
  end

  test "there are admin routes to check" do
    assert_operator admin_routes.size, :>, 30
  end

  test "every admin route is a 404 on the auth and index hosts, even for a signed-in admin" do
    sign_in_index users(:mwi)
    [ auth_host, index_host ].each do |host|
      host! host
      checked = 0
      admin_routes.each do |route|
        verb = route.verb.presence || "GET"
        path = concrete_path(route)
        next if home_too?(route)
        process verb.split("|").first.downcase.to_sym, path
        assert_response :not_found, "#{verb} #{path} on #{host}"
        checked += 1
      end
      assert_operator checked, :>, 30
    end
  end

  test "the root of the auth host is no admin dashboard: it sends a signed-in admin to the index host" do
    sign_in_as users(:mwi)
    get "/"
    assert_redirected_to "http://index.example.com/"
  end

  test "admin pages need an admin session on the admin host" do
    on_admin_host!
    %w[/users /groups /apps /access /access.csv /tokens /audit].each do |path|
      get path
      assert_admin_sign_in_started
    end
    post "/users/#{users(:alice).id}/make_admin"
    assert_admin_sign_in_started
    assert_not users(:alice).reload.admin?
  end

  test "a non-admin gets 'not an admin' on every admin page" do
    sign_in_admin users(:mwi)
    users(:mwi).update_columns(admin: false)
    get "/users"
    assert_response :forbidden
    assert_select "h1", "Not an admin"
  end
end
