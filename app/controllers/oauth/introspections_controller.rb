# POST /oauth/introspect (RFC 7662; SPECS.md §9.2, §10): an app asks about a personal (tpa_…) or
# extension (tpx_…) token it received. The caller authenticates as its app's web client and learns
# only about its own app's tokens. Counted per client and day (UsageCount), not audited, and rate
# limited per client. The answer: Oidc::Introspection.
class Oauth::IntrospectionsController < Oauth::ApiController
  before_action :no_store!
  before_action :authenticate_client!
  rate_limit to: 600, within: 1.minute, store: RateLimitStore.store,
             by: -> { "introspect:#{Current.client.id}" }, with: -> { RateLimitStore.json_refusal(self) }

  def create
    return render(json: { error: "invalid_request", error_description: "token is required" }, status: :bad_request) if params[:token].blank?
    UsageCount.increment!(Current.client, "introspect")
    render json: Oidc::Introspection.call(Current.client, params[:token].to_s)
  end
end
