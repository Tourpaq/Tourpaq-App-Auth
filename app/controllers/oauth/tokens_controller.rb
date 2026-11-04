# POST /oauth/token (SPECS.md §7.1, §10, §25.5): grant_type authorization_code (web clients with
# client_secret_basic or client_secret_post; extension clients with client_id and PKCE), refresh_token
# (extension clients only) and the token exchange (urn:ietf:params:oauth:grant-type:token-exchange, the MCP
# Gateway's web client only). The grants themselves: Oidc::TokenGrant and Oidc::TokenExchange.
#
# The exchange has its own, larger budget per client (the gateway asks for every person and app it serves, from one
# address); the other grants keep theirs per client and address.
class Oauth::TokensController < Oauth::ApiController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore.store, unless: :exchange?,
             by: -> { "token:#{claimed_client_id}:#{request.remote_ip}" }, with: -> { RateLimitStore.json_refusal(self) }
  rate_limit to: 600, within: 1.minute, store: RateLimitStore.store, if: :exchange?, name: "exchange",
             by: -> { "exchange:#{claimed_client_id}" }, with: -> { RateLimitStore.json_refusal(self) }

  before_action :no_store!
  before_action -> { authenticate_client!(public: true) }

  def create
    body = case params[:grant_type]
    when "authorization_code"
      Oidc::TokenGrant.authorization_code(client: Current.client, code: params[:code].to_s,
                                          redirect_uri: params[:redirect_uri].to_s, code_verifier: params[:code_verifier].presence)
    when "refresh_token"
      Oidc::TokenGrant.refresh_token(client: Current.client, refresh_token: params[:refresh_token].to_s)
    when Oidc::TokenExchange::GRANT_TYPE
      Oidc::TokenExchange.call(client: Current.client, subject_token: params[:subject_token].to_s, audience: params[:audience].to_s,
                               subject_token_type: params[:subject_token_type].presence,
                               requested_token_type: params[:requested_token_type].presence)
    else
      raise Oidc::Error.new("unsupported_grant_type", "grant_type must be authorization_code, refresh_token or #{Oidc::TokenExchange::GRANT_TYPE}")
    end
    render json: body
  rescue Oidc::Error => e
    render_oauth_error(e)
  end

  private

  def exchange? = params[:grant_type] == Oidc::TokenExchange::GRANT_TYPE
end
