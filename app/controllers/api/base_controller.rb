# Base of the authorization API (SPECS.md §8): JSON, no cookies. The caller authenticates with its
# app's web client (client_secret_basic; ClientAuthentication) and can only ask about that app.
# A disabled client, or a client of a disabled app, is refused (401). Calls are counted per client
# and day (UsageCount "access"), not audited, and rate limited per client.
class Api::BaseController < ActionController::API
  include ClientAuthentication

  # A malformed JSON body (PUT /api/v1/catalogue) is the caller's mistake, not a server error.
  rescue_from ActionDispatch::Http::Parameters::ParseError do
    render json: { error: "invalid_request", error_description: "The body is not JSON" }, status: :bad_request
  end

  before_action :set_current_request
  before_action :authenticate_client!
  rate_limit to: 600, within: 1.minute, store: RateLimitStore.store,
             by: -> { "api:#{Current.client.id}" }, with: -> { RateLimitStore.json_refusal(self) }
  before_action { UsageCount.increment!(Current.client, "access") }

  private

  def set_current_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel = "api"
  end

  def current_app = Current.client.app
end
