# GET /oauth/logout (SPECS.md §7.5; OIDC RP-Initiated Logout): an app ends the auth session too.
#
# - id_token_hint: one of our ID tokens (expired is fine). It names the client and the user.
# - post_logout_redirect_uri: must be registered for that client (exact match), or for client_id when
#   no hint is given; the browser goes there afterwards, with the state.
# - With a valid hint for the signed-in user the auth session ends at once (auth.logout). A hint for
#   somebody else leaves the current person signed in. Without a valid hint the user is asked to
#   confirm (POST /oauth/logout), so a link on another site cannot sign people out.
# The Microsoft session is not touched, and the other apps' sessions are the apps' own (§7.5).
class Oauth::LogoutsController < ApplicationController
  allow_unauthenticated_access
  rate_limit to: 30, within: 1.minute, store: RateLimitStore.store, by: -> { "logout:#{request.remote_ip}" },
             with: -> { render_error_page("Too many sign-out requests. Wait a minute.", :too_many_requests) }

  before_action :load_request

  def show
    if resume_session
      if @hint.nil?
        return render(:confirm)
      elsif @hint["sub"] == current_user.sub
        sign_out_here
      end
    end
    @post_logout_uri ? redirect_to(client_return_url, allow_other_host: true) : render(:signed_out)
  end

  # The confirmation's button. A cross-origin redirect after a form post would break the CSP
  # (form-action), so the way back to the app is a link on the "signed out" page.
  def create
    sign_out_here if resume_session
    @back_url = client_return_url if @post_logout_uri
    render :signed_out
  end

  private

  def load_request
    @hint = verified_hint
    hint_client_id = @hint && Array(@hint["aud"]).first
    if hint_client_id && params[:client_id].present? && params[:client_id] != hint_client_id
      return render_error_page("The sign-out request names two different apps.")
    end
    @client = Client.find_active(hint_client_id || params[:client_id])
    return if params[:post_logout_redirect_uri].blank?
    @post_logout_uri = @client&.post_logout_redirect_uris&.detect { _1 == params[:post_logout_redirect_uri].to_s }
    render_error_page("The app gave a return address that is not registered for it.") unless @post_logout_uri
  end

  def verified_hint
    Oidc::IdToken.verify_hint(params[:id_token_hint]) if params[:id_token_hint].present?
  rescue Oidc::InvalidToken
    nil
  end

  def sign_out_here
    AuditEvent.record("auth.logout", subject: current_user, actor: current_user, app: @client&.app,
                      data: { session_id: Current.session.id, client_id: @client&.client_id }.compact)
    terminate_session("signed_out")
  end

  # The registered post-logout URI with the state added to its own query.
  def client_return_url
    uri = URI.parse(@post_logout_uri)
    query = URI.decode_www_form(uri.query.to_s)
    query << [ "state", params[:state].to_s ] if params[:state].present?
    uri.query = query.any? ? URI.encode_www_form(query) : nil
    uri.to_s
  end

  def render_error_page(message, status = :bad_request)
    @message = message
    render "oauth/authorizations/error", status: status
  end
end
