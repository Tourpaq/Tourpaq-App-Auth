# The index host's OIDC callback, /sso/callback (SPECS.md §24.1): the index host is the internal client
# "index" of this app's own OIDC provider (IndexAuthentication#start_index_sign_in sent the browser).
#
# 1. The state must match the one kept in the index host's session (constant time), and the sign-in must be
#    younger than 10 minutes.
# 2. The code is exchanged in-process (Oidc::TokenGrant, the same code as POST /oauth/token: single use,
#    exact redirect URI, PKCE S256 with the kept verifier, the user still active, the auth session alive).
# 3. The ID token is verified like any client would: signature against our JWKS, issuer, audience "index",
#    expiry and the kept nonce.
# 4. complete_index_sign_in starts the index session, counted from the Entra sign-in behind the auth session.
#    Failures are audited (auth.login_refused, kind: index) and show a page with "Try again".
class Index::SsoController < Index::BaseController
  LOGIN_TTL = 10.minutes

  allow_unauthenticated_index_access
  rate_limit to: 20, within: 1.minute, store: RateLimitStore.store, by: -> { "index_sso:#{request.remote_ip}" },
             with: -> { refuse("too_many_attempts", "Too many sign-in attempts. Wait a minute.", status: :too_many_requests) }

  def callback
    pending = session.delete(INDEX_SSO_KEY)
    unless pending.is_a?(Hash) && pending["state"].present? &&
           ActiveSupport::SecurityUtils.secure_compare(pending["state"].to_s, params[:state].to_s)
      return refuse("state", "This sign-in was not started in this browser.")
    end
    return refuse("timeout", "The sign-in took too long.") if pending["at"].to_i < LOGIN_TTL.ago.to_i
    return refuse(params[:error].to_s, "The sign-in was refused (#{params[:error]}).") if params[:error].present?

    tokens = Oidc::TokenGrant.authorization_code(client: Client.index_client, code: params[:code].to_s,
                                                 redirect_uri: AuthHosts.index_callback_url, code_verifier: pending["verifier"])
    claims = Oidc::IdToken.verify(tokens["id_token"], audience: Client::INDEX_CLIENT_ID, nonce: pending["nonce"])
    user = User.find_by(sub: claims["sub"])
    return refuse("unknown_user", "The sign-in could not be completed.") unless user&.active?

    signed_in_at = tokens["entra_authenticated_at"] ? Time.zone.at(tokens["entra_authenticated_at"].to_i) : Time.current
    auth_time = claims["auth_time"] ? Time.zone.at(claims["auth_time"].to_i) : nil
    complete_index_sign_in(user, entra_authenticated_at: [ signed_in_at, Time.current ].min, entra_auth_time: auth_time)
  rescue Oidc::Error => e
    refuse(e.code, "The sign-in could not be completed (#{e.description || e.code}).")
  rescue Oidc::InvalidToken => e
    refuse("invalid_id_token", "The sign-in could not be verified.", detail: e.message)
  end

  private

  def refuse(reason, message, status: :forbidden, detail: nil)
    AuditEvent.record("auth.login_refused", actor: nil, data: { kind: "index", reason: reason, detail: detail&.truncate(200) }.compact)
    @message = message
    render "index/sso/failed", status: status
  end
end
