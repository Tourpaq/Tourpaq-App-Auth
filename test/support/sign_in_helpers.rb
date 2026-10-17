# Signing in without real Entra:
#
#   sign_in_as(user)              AUTH host: through POST /auth/entra_id in OmniAuth test mode, as
#                                 the user's Entra account (their oid, or the fake IdP's for their
#                                 email). Leaves the test on the auth host, at the redirect after
#                                 sign-in.
#   sign_in_with_entra(email:, …) the same for any claims (first sign-ins, refusals)
#   sign_in_index(user)           INDEX host: signs in on the auth host (unless sign_in: false), then
#                                 the index host's real OIDC round trip as client "index" (authorize,
#                                 /sso/callback). Leaves the test on the index host, at the index's
#                                 first page (or where `path` led). A pending user ends at the auth
#                                 host's "waiting for access" redirect instead.
#   sign_in_admin(user)           ADMIN host: through the dev-only admin sign-in stub, which calls
#                                 AdminAuthentication#complete_admin_sign_in like the real OIDC
#                                 callback. Leaves the test on the admin host.
#   sign_out                      ends the auth session (DELETE /session on the auth host)
module SignInHelpers
  def sign_in_with_entra(email:, name: nil, **claims)
    on_auth_host!
    mock_entra(email: email, name: name, **claims)
    post "/auth/entra_id"
    follow_redirect! # to /auth/entra_id/callback
    response
  end

  def sign_in_as(user)
    sign_in_with_entra(email: user.email, name: user.name, oid: user.entra_oid.presence || FakeIdentity.oid_for(user.email),
                       tid: user.entra_tid.presence || entra_tenant_id)
    raise "sign-in as #{user.email} failed (#{response.status})" unless response.redirect?
    user
  end

  def sign_in_index(user, path: "/", sign_in: true)
    sign_in_as(user) if sign_in
    on_index_host!
    get path
    raise "the index host did not start its sign-in (#{response.status})" unless response.redirect? && URI(response.location).path == "/oauth/authorize"
    follow_redirect! # the auth host's /oauth/authorize
    raise "authorize as #{user.email} failed (#{response.status})" unless response.redirect? && response.location.start_with?(AuthHosts.index_callback_url)
    follow_redirect! # the index host's /sso/callback
    follow_redirect! if response.redirect? && URI(response.location).host == index_host
    user
  end

  def sign_out
    on_auth_host!
    delete session_path
  end

  def sign_in_admin(user)
    on_admin_host!
    post dev_admin_sign_in_path, params: { email: user.email }
    user
  end
end
