require "test_helper"

class SessionsControllerTest < ActionController::TestCase
  test "coming from an app's /oauth request, the sign-in page goes straight on to Microsoft" do
    get :new, session: { return_to: "/oauth/authorize?client_id=irm-web" }
    assert_select "form[action='/auth/entra_id'][data-controller=autosubmit]"
  end

  test "otherwise, and after a sign out (stay), it shows the button only" do
    get :new
    assert_select "form[action='/auth/entra_id']"
    assert_select "form[data-controller=autosubmit]", 0
    get :new, params: { stay: 1 }, session: { return_to: "/oauth/authorize?client_id=irm-web" }
    assert_select "form[data-controller=autosubmit]", 0
  end

  test "a forced fresh sign-in is kept server-side, not in the form, and the page says so" do
    get :new, session: { entra_prompt: "login", entra_fresh_after: Time.current.to_i }
    assert_select "input[name=prompt]", 0
    assert_select "p.hint", /password again/
    assert_equal "login", session[:entra_prompt], "kept for the Entra strategy and the callback"
  end
end
