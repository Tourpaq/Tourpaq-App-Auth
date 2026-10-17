# The admin host's OIDC callback, /sso/callback (SPECS.md §11.2): the admin host is the internal client
# "admin" of this app's own OIDC provider (AdminAuthentication#start_admin_sign_in sent the browser).
#
# 1. The state must match the one kept in the admin host's session (constant time), and the sign-in
#    must be younger than 10 minutes.
# 2. The code is exchanged in-process (Oidc::TokenGrant, the same code as POST /oauth/token: single
#    use, exact redirect URI, PKCE S256 with the kept verifier).
# 3. The ID token is verified like any client would: signature against our JWKS, issuer, audience
#    "admin", expiry, the kept nonce; and its auth_time must be within ADMIN_REAUTH_HOURS.
# 4. complete_admin_sign_in starts the admin session (12 h counted from auth_time) or refuses a
#    non-admin. Failures are audited (auth.login_refused) and show a page with "Try again".
class Admin::SsoController < Admin::BaseController
  LOGIN_TTL = 10.minutes

  allow_unauthenticated_admin_access
  rate_limit to: 20, within: 1.minute, store: RateLimitStore.store, by: -> { "admin_sso:#{request.remote_ip}" },
             with: -> { refuse("too_many_attempts", "Too many sign-in attempts. Wait a minute.", status: :too_many_requests) }

  def callback
    pending = session.delete(ADMIN_SSO_KEY)
    unless pending.is_a?(Hash) && pending["state"].present? &&
           ActiveSupport::SecurityUtils.secure_compare(pending["state"].to_s, params[:state].to_s)
      return refuse("state", "This sign-in was not started in this browser.")
    end
    return refuse("timeout", "The sign-in took too long.") if pending["at"].to_i < LOGIN_TTL.ago.to_i
    return refuse(params[:error].to_s, "The sign-in was refused (#{params[:error]}).") if params[:error].present?

    tokens = Oidc::TokenGrant.authorization_code(client: Client.admin_client, code: params[:code].to_s,
                                                 redirect_uri: AuthHosts.admin_callback_url, code_verifier: pending["verifier"])
    claims = Oidc::IdToken.verify(tokens["id_token"], audience: Client::ADMIN_CLIENT_ID, nonce: pending["nonce"])
    authenticated_at = Time.zone.at(claims["auth_time"].to_i)
    if authenticated_at < Rails.configuration.x.auth.admin_reauth.ago
      return refuse("max_age", "Your Microsoft sign-in is too old for the admin pages.")
    end

    complete_admin_sign_in(User.find_by(sub: claims["sub"]), authenticated_at: authenticated_at)
  rescue Oidc::Error => e
    refuse(e.code, "The sign-in could not be completed (#{e.description || e.code}).")
  rescue Oidc::InvalidToken => e
    refuse("invalid_id_token", "The sign-in could not be verified.", detail: e.message)
  end

  private

  def refuse(reason, message, status: :forbidden, detail: nil)
    AuditEvent.record("auth.login_refused", actor: nil, data: { kind: "admin", reason: reason, detail: detail&.truncate(200) }.compact)
    @message = message
    render "admin/sso/failed", status: status
  end
end
