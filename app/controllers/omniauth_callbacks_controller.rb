# Entra's redirect back, /auth/entra_id/callback (SPECS.md §3.1). The OmniAuth middleware has already
# exchanged the code and verified the ID token (lib/omniauth/strategies/tourpaq_entra_id.rb); this
# finds or creates the user and starts the auth session.
class OmniauthCallbacksController < ApplicationController
  allow_unauthenticated_access
  skip_forgery_protection only: :failure # called by OmniAuth's middleware, also for a failed POST start
  rate_limit to: 20, within: 1.minute, only: :entra_id,
             with: -> { @message = "Too many sign-in attempts. Wait a minute."; render("sessions/refused", status: :too_many_requests) }

  def entra_id
    sign_in_from_entra(request.env["omniauth.auth"])
  end

  # OmniAuth.config.on_failure: a refused or broken sign-in (state/CSRF, nonce, signature, tenant,
  # Entra error). Audited with the reason; the browser gets a plain page with "Try again".
  def failure
    error = request.env["omniauth.error"]
    type = request.env["omniauth.error.type"] || params[:message]
    reason = error.respond_to?(:error_reason) && error.error_reason.present? ? error.error_reason : error&.message
    # state_check (set by the strategy's callback): for csrf_detected, whether the browser sent no session cookie,
    # had no sign-in attempt in it, or only attempts with other states.
    AuditEvent.record("auth.login_refused", actor: nil,
                      data: { reason: type.to_s, detail: reason.to_s.truncate(300),
                              state_check: request.env["tpa.entra.state_check"] }.compact_blank)
    @message = type.to_s == "invalid_id_token" && reason.to_s.include?("tenant") ? EntraSignIn::MESSAGES[:wrong_tenant] : "The sign-in with Microsoft did not complete (#{type}). Try again."
    render "sessions/refused", status: :forbidden
  end
end
