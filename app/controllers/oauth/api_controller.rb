# Base of the OIDC provider's machine endpoints (SPECS.md §7.1): JSON only, no cookies, no CSRF
# (clients authenticate themselves, ClientAuthentication). The browser-facing endpoints
# (/oauth/authorize, /oauth/logout) inherit ApplicationController instead.
class Oauth::ApiController < ActionController::API
  include ClientAuthentication

  before_action :set_current_request

  private

  def set_current_request
    Current.ip_address = request.remote_ip
    Current.user_agent = request.user_agent
    Current.channel = "api"
  end
end
