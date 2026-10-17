# Sign-in on the AUTH host (SPECS.md §3.3, §24.1): the Entra sign-in. A server-side Session row (kind "home",
# a name older than the auth host) whose random
# token sits in a signed, host-only, HttpOnly, SameSite=Lax cookie. It ends after
# SESSION_IDLE_HOURS idle or SESSION_MAX_DAYS after the Entra sign-in, after which the next
# request goes through Entra again.
#
# Included in ApplicationController, so every auth-host controller requires a signed-in user unless it
# says `allow_unauthenticated_access`. Interface for other controllers:
#
#   current_user / signed_in?                 (also helpers)
#   require_sign_in                           before_action: resumes the session or stores the
#                                             return-to (GET only) and redirects to sign-in
#   resume_session                            the session if there is one, without requiring it
#   request_sign_in(return_to:, prompt:)      send the browser to sign in, then back to return_to
#                                             (a local path such as /oauth/authorize?…);
#                                             prompt: "login" makes Entra ask for credentials again
#                                             (kept server-side, and verified at the callback)
#   require_recent_sign_in(max_age)           re-run Entra when the person last gave Entra their
#                                             credentials longer ago than max_age
#   sign_in_from_entra(auth_hash)             finish a sign-in (OmniAuth callback, fake IdP)
#   terminate_session(reason)                 sign out
module Authentication
  extend ActiveSupport::Concern

  COOKIE = :home_session

  # A fresh Entra sign-in (credentials typed again) was asked for at this time (Unix seconds). It lives in
  # the Rails session, never in the browser's form: the Entra strategy sends prompt=login from it, and the
  # callback refuses an Entra sign-in whose auth_time is older (SPECS.md §3.1, §7.6).
  FRESH_SIGN_IN_KEY = :entra_fresh_after

  included do
    before_action :set_current_request
    before_action :require_sign_in
    helper_method :current_user, :signed_in?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_sign_in, **options
    end
  end

  private

  def current_user = Current.session&.home? ? Current.user : nil
  def signed_in? = current_user.present?

  def set_current_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel ||= "web"
  end

  def require_sign_in
    resume_session || request_sign_in
  end

  def resume_session
    return Current.session if Current.session&.home?
    row = Session.find_by_plain(cookies.signed[COOKIE], kind: "home")
    return forget_session_cookie unless row
    reason = row.expiry_reason || ("disabled" if row.user.disabled?)
    if reason
      row.end!(reason)
      AuditEvent.record("session.expired", subject: row.user, actor: row.user, data: { session_id: row.id, reason: reason })
      return forget_session_cookie
    end
    row.touch_seen!(ip_address: request.remote_ip)
    Current.session = row
  end

  def request_sign_in(return_to: (request.fullpath if request.get?), prompt: nil)
    session[:return_to] = return_to if safe_return_to?(return_to)
    if prompt == "login"
      session[:entra_prompt] = "login"
      session[FRESH_SIGN_IN_KEY] = Time.current.to_i
    end
    redirect_to sign_in_path
  end

  # For flows that need credentials given to Entra recently.
  def require_recent_sign_in(max_age)
    entra_auth_time = Current.session&.entra_auth_time
    return true if entra_auth_time && entra_auth_time >= max_age.ago
    request_sign_in(return_to: request.fullpath, prompt: "login")
    false
  end

  # Called by the OmniAuth callback and by the fake identity provider with the same auth hash.
  def sign_in_from_entra(auth)
    entra_auth_time = entra_auth_time_from(auth)
    return refuse_stale_entra_sign_in(auth) unless fresh_enough?(entra_auth_time)

    result = EntraSignIn.call(auth)
    unless result.success?
      @message = result.message
      return render("sessions/refused", status: :forbidden)
    end
    start_session_for(result.user, entra_auth_time: entra_auth_time)
    AuditEvent.record("auth.login", subject: result.user, actor: result.user, data: { session_id: Current.session.id })
    redirect_to after_sign_in_path
  end

  # Entra's auth_time claim (when credentials were last given to Entra), never later than now; nil when absent.
  def entra_auth_time_from(auth)
    raw = auth.respond_to?(:extra) && auth.extra ? auth.extra.raw_info : nil
    value = raw.respond_to?(:[]) ? raw["auth_time"] : nil
    return nil unless value.is_a?(Integer) || value.to_s.match?(/\A\d{1,12}\z/)
    [ Time.zone.at(value.to_i), Time.current ].min
  end

  # When a fresh sign-in was asked for, Entra must say it asked for credentials since then: the browser
  # can drop prompt=login on its way to Microsoft, but not change the signed auth_time.
  def fresh_enough?(entra_auth_time)
    asked_at = session[FRESH_SIGN_IN_KEY]
    return true if asked_at.blank?
    entra_auth_time.present? && entra_auth_time.to_i >= asked_at.to_i - Session::FRESH_SIGN_IN_LEEWAY.to_i
  end

  def refuse_stale_entra_sign_in(auth)
    raw = auth.respond_to?(:extra) && auth.extra ? auth.extra.raw_info.to_h : {}
    AuditEvent.record("auth.login_refused", actor: nil,
                      data: { reason: "not_fresh", email: raw["email"].presence || raw["preferred_username"],
                              auth_time: raw["auth_time"] }.compact)
    @message = "This sign-in needs you to enter your Microsoft password again, and Microsoft did not ask for it. Try again."
    render "sessions/refused", status: :forbidden
  end

  # A new session for a user who just signed in with Entra. Resets the Rails session (fixation, and the
  # fresh sign-in request it held) but keeps where the user was going.
  def start_session_for(user, entra_authenticated_at: Time.current, entra_auth_time: nil)
    return_to = session[:return_to]
    reset_session
    session[:return_to] = return_to if return_to
    row, plain = Session.start!(user: user, kind: "home", ip_address: request.remote_ip, user_agent: request.user_agent,
                                entra_authenticated_at: entra_authenticated_at, entra_auth_time: entra_auth_time)
    cookies.signed[COOKIE] = { value: plain, httponly: true, same_site: :lax, secure: request.ssl?,
                               expires: Rails.configuration.x.auth.session_max.from_now }
    Current.session = row
  end

  def after_sign_in_path
    return_to = session.delete(:return_to)
    safe_return_to?(return_to) ? return_to : root_path
  end

  def terminate_session(reason = "signed_out")
    Current.session&.end!(reason)
    Current.session = nil
    forget_session_cookie
    reset_session
  end

  def forget_session_cookie
    cookies.delete(COOKIE) if cookies[COOKIE]
    nil
  end

  # Only local paths: "/x", never "//host" or "/\host".
  def safe_return_to?(path) = path.is_a?(String) && path.start_with?("/") && !path.start_with?("//", "/\\")
end
