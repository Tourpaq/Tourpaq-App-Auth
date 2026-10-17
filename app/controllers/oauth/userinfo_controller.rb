# GET or POST /oauth/userinfo with "Authorization: Bearer <access token>" (SPECS.md §7.3): the same
# claims as the ID token, with the role in the client's app as of now. The access token must be
# live and its user must still be active with access.
class Oauth::UserinfoController < Oauth::ApiController
  rate_limit to: 120, within: 1.minute, store: RateLimitStore.store,
             by: -> { "userinfo:#{request.remote_ip}" }, with: -> { RateLimitStore.json_refusal(self) }

  before_action :no_store!

  def show
    token = bearer_token
    record = token ? OauthToken.access.includes(:user, client: :app).find_by(token_digest: HashedToken.digest(token)) : nil
    unless record&.usable? && Oidc::Access.allowed?(record.user, record.client)
      response.set_header("WWW-Authenticate", %(Bearer error="invalid_token"))
      return render(json: { error: "invalid_token" }, status: :unauthorized)
    end
    render json: Oidc::IdToken.user_claims(record.user, record.client)
  end

  private

  def bearer_token
    request.authorization.to_s[/\ABearer +(\S+)\z/i, 1]
  end
end
