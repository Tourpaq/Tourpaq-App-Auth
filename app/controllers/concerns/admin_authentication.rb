# Sign-in on the ADMIN host (SPECS.md §11.2). Its own server-side Session (kind "admin") in its own
# host-only cookie: an auth or index session is no session here and vice versa. It ends after
# ADMIN_SESSION_IDLE_HOURS idle or ADMIN_REAUTH_HOURS after the Entra sign-in behind it.
#
# On every request: the client address must be in ADMIN_ALLOWED_CIDRS (when set; X-Forwarded-For
# is trusted only from TRUSTED_PROXIES / Rails' private ranges), and the user must still be an
# active admin, or the admin session ends and "not an admin" is shown (audited admin.denied).
#
# Interface:
#   current_admin / admin_signed_in?          (also helpers)
#   require_admin                             before_action (skip with allow_unauthenticated_admin_access)
#   complete_admin_sign_in(user, authenticated_at:)
#                                             start the admin session after the admin client's
#                                             OIDC callback (Admin::SsoController) has verified the
#                                             ID token; refuses non-admins
#   start_admin_sign_in                       redirect to the auth host's /oauth/authorize as the internal
#                                             client "admin" (state, nonce, PKCE, max_age)
#   end_admin_session(reason)                 sign out
module AdminAuthentication
  extend ActiveSupport::Concern

  COOKIE = :admin_session

  included do
    layout "admin"
    before_action :set_current_admin_request
    before_action :require_admin_network
    before_action :require_admin
    helper_method :current_admin, :admin_signed_in?
  end

  class_methods do
    def allow_unauthenticated_admin_access(**options)
      skip_before_action :require_admin, **options
    end
  end

  private

  def current_admin = Current.session&.admin? ? Current.user : nil
  def admin_signed_in? = current_admin.present?

  def set_current_admin_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel = "admin"
  end

  def require_admin
    return start_admin_sign_in unless resume_admin_session
    deny_admin(current_admin) unless current_admin.admin? && current_admin.active?
  end

  def resume_admin_session
    return Current.session if Current.session&.admin?
    row = Session.find_by_plain(cookies.signed[COOKIE], kind: "admin")
    return forget_admin_cookie unless row
    if (reason = row.expiry_reason)
      row.end!(reason)
      AuditEvent.record("session.expired", subject: row.user, actor: row.user, data: { session_id: row.id, reason: reason, kind: "admin" })
      return forget_admin_cookie
    end
    row.touch_seen!(ip_address: request.remote_ip)
    Current.session = row
  end

  # The admin host signs in through this app's own OIDC provider (§11.2), as the internal client
  # "admin": state, nonce and a PKCE verifier are kept in the admin host's own Rails session, and the
  # browser goes to the auth host's /oauth/authorize with max_age = ADMIN_REAUTH_HOURS, which sends the admin
  # through Entra again when their last Entra sign-in is older. Admin::SsoController#callback
  # finishes it (exchange in-process, ID token verified) and calls complete_admin_sign_in.
  ADMIN_SSO_KEY = :admin_sso

  def start_admin_sign_in
    session[:admin_return_to] = request.fullpath if request.get? || request.head?
    client = Client.admin_client
    pending = { "state" => SecureRandom.urlsafe_base64(32), "nonce" => SecureRandom.urlsafe_base64(32),
                "verifier" => SecureRandom.urlsafe_base64(48), "at" => Time.current.to_i }
    session[ADMIN_SSO_KEY] = pending
    query = {
      response_type: "code", client_id: client.client_id, redirect_uri: AuthHosts.admin_callback_url,
      scope: "openid email profile", state: pending["state"], nonce: pending["nonce"],
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(pending["verifier"]), padding: false),
      code_challenge_method: "S256", max_age: Rails.configuration.x.auth.admin_reauth.to_i
    }
    redirect_to "#{AuthHosts.auth_url}/oauth/authorize?#{query.to_query}", allow_other_host: true
  end

  # Starts the admin session for a user whose identity was just verified. Non-admins and disabled
  # users get "not an admin" instead. authenticated_at: the Entra sign-in time (ID token auth_time).
  def complete_admin_sign_in(user, authenticated_at:)
    return deny_admin(user) unless user&.admin? && user.active?
    return_to = session[:admin_return_to]
    reset_session
    row, plain = Session.start!(user: user, kind: "admin", ip_address: request.remote_ip, user_agent: request.user_agent,
                                entra_authenticated_at: authenticated_at)
    cookies.signed[COOKIE] = { value: plain, httponly: true, same_site: :lax, secure: request.ssl? }
    Current.session = row
    AuditEvent.record("auth.login", subject: user, actor: user, data: { session_id: row.id, kind: "admin" })
    redirect_to(safe_admin_return_to?(return_to) ? return_to : admin_root_path)
  end

  def deny_admin(user)
    end_admin_session("not_admin") if Current.session&.admin?
    AuditEvent.record("admin.denied", subject: user, actor: user, data: { path: request.path, reason: user&.disabled? ? "disabled" : "not_admin" })
    render "admin/sessions/not_admin", status: :forbidden
  end

  def require_admin_network
    cidrs = Rails.configuration.x.auth.admin_allowed_cidrs
    return if cidrs.blank?
    ip = IPAddr.new(request.remote_ip) rescue nil
    return if ip && cidrs.any? { _1.include?(ip) }
    AuditEvent.record("admin.denied", actor: nil, data: { path: request.path, reason: "network", ip: request.remote_ip })
    render plain: "The admin host is not available from your network.", status: :forbidden
  end

  def end_admin_session(reason = "signed_out")
    Current.session&.end!(reason)
    Current.session = nil
    forget_admin_cookie
  end

  def forget_admin_cookie
    cookies.delete(COOKIE) if cookies[COOKIE]
    nil
  end

  def safe_admin_return_to?(path) = path.is_a?(String) && path.start_with?("/") && !path.start_with?("//", "/\\")
end
