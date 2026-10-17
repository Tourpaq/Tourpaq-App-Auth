# Sign-in on the INDEX host (SPECS.md §24.1). The index host is the internal OIDC client "index" of this
# app's own provider, exactly like the admin host (AdminAuthentication): it sends the browser to the auth
# host's /oauth/authorize (state, nonce, PKCE S256), Index::SsoController#callback exchanges the code
# in-process and verifies the ID token, and complete_index_sign_in starts the index host's own session.
#
# Its own server-side Session (kind "index") in its own host-only cookie: an auth (home) or admin session is
# no session here and vice versa. It ends after SESSION_IDLE_HOURS idle (8) or SESSION_MAX_DAYS (7) after the
# Entra sign-in behind the auth session it came from, or at the user's "sign out everywhere". On every request
# the user must still be active (a disabled user's index session ends at once); a user without any access yet
# (User#pending?) is sent to the auth host's "waiting for access" page.
#
# Included in Index::BaseController, so every index controller requires a signed-in user unless it says
# allow_unauthenticated_index_access. Interface for other controllers (and the index module):
#
#   current_user / index_signed_in?           (also helpers) the signed-in user on the index host, or nil
#   require_index_sign_in                     before_action: resumes the index session, or starts the sign-in
#                                             through the auth host (GET/HEAD: back to this path afterwards)
#   resume_index_session                      the session if there is one, without requiring it
#   start_index_sign_in                       redirect to the auth host's /oauth/authorize as client "index"
#   complete_index_sign_in(user, entra_authenticated_at:, entra_auth_time:)
#                                             start the index session after the callback verified the ID token
#   end_index_session(reason)                 end this host's session (sign out)
module IndexAuthentication
  extend ActiveSupport::Concern

  COOKIE = :index_session
  INDEX_SSO_KEY = :index_sso

  included do
    layout "index"
    before_action :set_current_index_request
    before_action :require_index_sign_in
    helper_method :current_user, :index_signed_in?
  end

  class_methods do
    def allow_unauthenticated_index_access(**options)
      skip_before_action :require_index_sign_in, **options
    end
  end

  private

  def current_user = Current.session&.index? ? Current.user : nil
  def index_signed_in? = current_user.present?

  def set_current_index_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel ||= "web"
  end

  def require_index_sign_in
    return start_index_sign_in unless resume_index_session
    redirect_to AuthHosts.waiting_url, allow_other_host: true if current_user.pending?
  end

  def resume_index_session
    return Current.session if Current.session&.index?
    row = Session.find_by_plain(cookies.signed[COOKIE], kind: "index")
    return forget_index_cookie unless row
    reason = row.expiry_reason || ("disabled" if row.user.disabled?)
    if reason
      row.end!(reason)
      AuditEvent.record("session.expired", subject: row.user, actor: row.user, data: { session_id: row.id, reason: reason, kind: "index" })
      return forget_index_cookie
    end
    row.touch_seen!(ip_address: request.remote_ip)
    Current.session = row
  end

  # state, nonce and a PKCE verifier are kept in the index host's own (host-only) Rails session; the browser
  # goes to the auth host's /oauth/authorize, which signs the user in with Entra first when needed.
  def start_index_sign_in
    session[:index_return_to] = request.fullpath if request.get? || request.head?
    pending = { "state" => SecureRandom.urlsafe_base64(32), "nonce" => SecureRandom.urlsafe_base64(32),
                "verifier" => SecureRandom.urlsafe_base64(48), "at" => Time.current.to_i }
    session[INDEX_SSO_KEY] = pending
    query = {
      response_type: "code", client_id: Client.index_client.client_id, redirect_uri: AuthHosts.index_callback_url,
      scope: "openid email profile", state: pending["state"], nonce: pending["nonce"],
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(pending["verifier"]), padding: false),
      code_challenge_method: "S256"
    }
    redirect_to "#{AuthHosts.auth_url}/oauth/authorize?#{query.to_query}", allow_other_host: true
  end

  # Starts the index session for a user whose identity was just verified. entra_authenticated_at: the Entra
  # sign-in behind the auth session (its lifetime counts from it); entra_auth_time: the ID token's auth_time.
  def complete_index_sign_in(user, entra_authenticated_at:, entra_auth_time: nil)
    return_to = session[:index_return_to]
    reset_session
    row, plain = Session.start!(user: user, kind: "index", ip_address: request.remote_ip, user_agent: request.user_agent,
                                entra_authenticated_at: entra_authenticated_at, entra_auth_time: entra_auth_time)
    cookies.signed[COOKIE] = { value: plain, httponly: true, same_site: :lax, secure: request.ssl?,
                               expires: Rails.configuration.x.auth.session_max.from_now }
    Current.session = row
    AuditEvent.record("auth.login", subject: user, actor: user, data: { session_id: row.id, kind: "index" })
    return redirect_to(AuthHosts.waiting_url, allow_other_host: true) if user.pending?
    redirect_to(safe_index_return_to?(return_to) ? return_to : index_root_path)
  end

  def end_index_session(reason = "signed_out")
    Current.session&.end!(reason)
    Current.session = nil
    forget_index_cookie
  end

  def forget_index_cookie
    cookies.delete(COOKIE) if cookies[COOKIE]
    nil
  end

  def safe_index_return_to?(path) = path.is_a?(String) && path.start_with?("/") && !path.start_with?("//", "/\\")
end
