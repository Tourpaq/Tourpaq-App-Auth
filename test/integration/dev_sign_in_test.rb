require "test_helper"

# The fake identity provider (SPECS.md §3.4).
class DevSignInTest < ActionDispatch::IntegrationTest
  test "lists users and signs in as one through the same code as Entra" do
    get "/dev/sign_in"
    assert_response :success
    assert_select "button", /Mogens Winther/
    post "/dev/sign_in", params: { email: "carol@contractor.example", name: "Carol C" }
    assert_redirected_to "/"
    carol = users(:carol).reload
    assert_equal FakeIdentity.oid_for("carol@contractor.example"), carol.entra_oid
    assert_equal %w[user.bound auth.login], AuditEvent.order(:id).last(2).map(&:action)
  end

  test "another tenant is refused like Entra's would be" do
    post "/dev/sign_in", params: { email: "x@other.example", tid: SecureRandom.uuid }
    assert_response :forbidden
  end

  test "the sign-in page links to it in development and test" do
    get "/sign_in"
    assert_select "a[href='/dev/sign_in']"
  end

  test "the admin stub lists the admins" do
    on_admin_host!
    get "/dev/admin_sign_in"
    assert_response :success
    assert_select "button", /Mogens Winther/
    assert_select "button", { text: /Alice/, count: 0 }
  end
end
