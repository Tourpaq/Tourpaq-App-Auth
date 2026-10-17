# POST /oauth/token (SPECS.md §7.1, §10): grant_type authorization_code (web clients with
# client_secret_basic or client_secret_post; extension clients with client_id and PKCE) and
# refresh_token (extension clients only). The grants themselves: Oidc::TokenGrant.
class Oauth::TokensController < Oauth::ApiController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore.store,
             by: -> { "token:#{claimed_client_id}:#{request.remote_ip}" }, with: -> { RateLimitStore.json_refusal(self) }

  before_action :no_store!
  before_action -> { authenticate_client!(public: true) }

  def create
    body = case params[:grant_type]
    when "authorization_code"
      Oidc::TokenGrant.authorization_code(client: Current.client, code: params[:code].to_s,
                                          redirect_uri: params[:redirect_uri].to_s, code_verifier: params[:code_verifier].presence)
    when "refresh_token"
      Oidc::TokenGrant.refresh_token(client: Current.client, refresh_token: params[:refresh_token].to_s)
    else
      raise Oidc::Error.new("unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
    end
    render json: body
  rescue Oidc::Error => e
    render_oauth_error(e)
  end
end
