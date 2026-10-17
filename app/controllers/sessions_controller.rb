# The auth host's sign-in page and sign out (SPECS.md §3). The sign-in itself is
# POST /auth/entra_id (OmniAuth) → Entra → OmniauthCallbacksController.
class SessionsController < ApplicationController
  allow_unauthenticated_access

  def new
    # A signed-in user is only sent through Entra again when a fresh sign-in was asked for
    # (request_sign_in(prompt: "login"): an app's prompt=login / max_age, the admin host's 12 hours).
    return redirect_to(root_path) if resume_session && session[:entra_prompt].blank?
    # The prompt stays in the Rails session: the Entra strategy reads it there (a form field could be
    # dropped by the browser), and the callback checks Entra's auth_time against it.
    @fresh = session[:entra_prompt] == "login"
    # Coming from an app (/oauth/…): go straight on to Microsoft, which is silent when its own
    # session is alive. Otherwise show the button.
    @auto = session[:return_to].to_s.start_with?("/oauth/") && params[:stay].blank?
  end

  def destroy
    if resume_session
      AuditEvent.record("auth.logout", subject: current_user, actor: current_user, data: { session_id: Current.session.id })
      terminate_session("signed_out")
    end
    redirect_to sign_in_path(stay: 1), notice: "You are signed out. You are still signed in to Microsoft."
  end
end
