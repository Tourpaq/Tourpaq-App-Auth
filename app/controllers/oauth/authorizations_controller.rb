# GET /oauth/authorize (SPECS.md §7.2, §10, §11.2): the authorization-code flow.
#
# 1. The client and its redirect URI are checked first (exact match). If either is wrong, the browser
#    gets our own error page and is never sent anywhere.
# 2. The request: response_type=code, scope with openid, state and nonce required, PKCE S256 (required
#    for public and internal clients, accepted for confidential ones; "plain" is refused), prompt
#    (none, login), max_age. Errors from here on go back to the redirect URI with the state.
# 3. An auth session is required. Without one the user signs in with Entra and comes back to this
#    very request (the foundation's return-to). prompt=login or max_age=0 always, and max_age when
#    the session's Entra sign-in is older, send the user through Entra again (prompt=login); a
#    signed marker in the return-to tells this action afterwards that the new sign-in happened.
#    prompt=none never shows a page: login_required instead.
# 4. No access to the client's app: our own "no access" page (or error=access_denied for
#    prompt=none), audited oauth.denied. There is no consent screen.
# 5. A single-use code (60 s) back to the redirect URI with the state, audited oauth.authorized.
class Oauth::AuthorizationsController < ApplicationController
  REAUTH_PARAM = "reauth".freeze
  REAUTH_TTL = 15.minutes
  CHALLENGE_FORMAT = /\A[A-Za-z0-9_-]{43}\z/

  allow_unauthenticated_access
  rate_limit to: 60, within: 1.minute, store: RateLimitStore.store, by: -> { "authorize:#{request.remote_ip}" },
             with: -> { render_error_page("Too many sign-in requests from your address. Wait a minute and try again.", :too_many_requests) }

  def new
    @client = Client.find_active(params[:client_id])
    @client = nil unless @client&.active?
    return render_error_page("The app that sent you here is not registered, or it is disabled.") unless @client
    @redirect_uri = @client.redirect_uris.detect { _1 == params[:redirect_uri].to_s }
    return render_error_page("The app that sent you here gave a return address that is not registered for it.") unless @redirect_uri

    if (problem = request_problem)
      return redirect_to_client(error: problem.first, error_description: problem.last)
    end

    prompts = params[:prompt].to_s.split
    silent = prompts.include?("none")
    unless resume_session
      return redirect_to_client(error: "login_required") if silent
      return request_sign_in(return_to: request.fullpath)
    end
    if reauthentication_needed?(prompts)
      return redirect_to_client(error: "login_required") if silent
      return request_sign_in(return_to: return_to_with_reauth_marker, prompt: "login")
    end

    unless Oidc::Access.allowed?(current_user, @client)
      AuditEvent.record("oauth.denied", subject: current_user, actor: current_user, app: @client.app,
                        data: { client_id: @client.client_id, prompt: params[:prompt].presence }.compact)
      return redirect_to_client(error: "access_denied", error_description: "You do not have access to this app") if silent
      @app_name = Oidc::Access.app_name(@client)
      return render(:no_access, status: :forbidden)
    end

    plain = issue_code
    redirect_to_client(code: plain)
  end

  private

  # [error, description] for a malformed request, or nil.
  def request_problem
    return [ "unsupported_response_type", "response_type must be code" ] unless params[:response_type] == "code"
    return [ "invalid_scope", "scope must include openid" ] unless params[:scope].to_s.split.include?("openid")
    return [ "invalid_request", "state is required" ] if params[:state].blank?
    return [ "invalid_request", "nonce is required" ] if params[:nonce].blank?
    prompts = params[:prompt].to_s.split
    return [ "invalid_request", "prompt=none cannot be combined with other values" ] if prompts.include?("none") && prompts.size > 1
    return [ "invalid_request", "max_age must be a whole number of seconds" ] if params[:max_age].present? && !params[:max_age].to_s.match?(/\A\d{1,9}\z/)
    if params[:code_challenge].present?
      return [ "invalid_request", "code_challenge_method must be S256" ] unless params[:code_challenge_method] == "S256"
      return [ "invalid_request", "code_challenge is malformed" ] unless params[:code_challenge].to_s.match?(CHALLENGE_FORMAT)
    elsif @client.requires_pkce? || @client.internal?
      return [ "invalid_request", "PKCE (code_challenge with S256) is required for this client" ]
    end
    nil
  end

  def max_age = params[:max_age].present? ? params[:max_age].to_i : nil

  # Decided on when the person last gave Entra their credentials (Entra's auth_time), not on when the
  # session started: a silent Entra sign-in is no fresh sign-in. Unknown (no auth_time) is too old.
  def reauthentication_needed?(prompts)
    if prompts.include?("login") || max_age == 0
      !reauthenticated_since_marker?
    else
      max_age.present? && !Current.session.credentials_given_since?(max_age.seconds.ago + Session::FRESH_SIGN_IN_LEEWAY)
    end
  end

  # The marker carries the time the new Entra sign-in was asked for, signed so it cannot be made up.
  def reauthenticated_since_marker?
    asked_at = reauth_verifier.verified(params[REAUTH_PARAM].to_s)
    asked_at.is_a?(Integer) && Current.session.credentials_given_since?(Time.zone.at(asked_at))
  end

  def return_to_with_reauth_marker
    query = request.query_parameters.except(REAUTH_PARAM)
    query[REAUTH_PARAM] = reauth_verifier.generate(Time.current.to_i, expires_in: REAUTH_TTL)
    "#{request.path}?#{query.to_query}"
  end

  def reauth_verifier = Rails.application.message_verifier("oauth_reauth")

  def issue_code
    code = AuthorizationCode.new(
      client: @client, user: current_user, session: Current.session, redirect_uri: @redirect_uri,
      code_challenge: params[:code_challenge].presence, code_challenge_method: (params[:code_challenge].present? ? "S256" : nil),
      nonce: params[:nonce].to_s, scope: Oidc::TokenGrant.granted_scopes(params[:scope]).join(" "),
      auth_time: Current.session.auth_time, expires_at: AuthorizationCode::CODE_TTL.from_now
    )
    plain = code.assign_new_token
    code.save!
    AuditEvent.record("oauth.authorized", subject: current_user, actor: current_user, app: @client.app,
                      data: { client_id: @client.client_id, scope: code.scope })
    plain
  end

  # Back to the client's registered redirect URI, keeping its own query, with the state.
  def redirect_to_client(values)
    uri = URI.parse(@redirect_uri)
    query = URI.decode_www_form(uri.query.to_s) + values.merge(state: params[:state].presence).compact.map { [ _1.to_s, _2.to_s ] }
    uri.query = URI.encode_www_form(query)
    redirect_to uri.to_s, allow_other_host: true
  end

  def render_error_page(message, status = :bad_request)
    @message = message
    render :error, status: status
  end
end
