# POST /oauth/revoke (RFC 7009; SPECS.md §7.1). A client revokes a token issued to itself: an access
# token alone, or a refresh token together with its whole chain (the extension signs out). Unknown
# tokens, and tokens of other clients, are answered 200 like a success, as RFC 7009 asks. Personal
# tokens are revoked by their owner on the Tokens page, not here.
class Oauth::RevocationsController < Oauth::ApiController
  rate_limit to: 60, within: 1.minute, store: RateLimitStore.store,
             by: -> { "revoke:#{claimed_client_id}:#{request.remote_ip}" }, with: -> { RateLimitStore.json_refusal(self) }

  before_action -> { authenticate_client!(public: true) }

  def create
    token = params[:token].to_s
    return render(json: { error: "invalid_request", error_description: "token is required" }, status: :bad_request) if token.blank?

    record = OauthToken.find_by(token_digest: HashedToken.digest(token))
    if record && record.client_id == Current.client.id && !record.revoked?
      if record.refresh?
        record.revoke_chain!
        AuditEvent.record("oauth.revoked", subject: record.user, actor: record.user, app: Current.client.app,
                          data: { client_id: Current.client.client_id, chain_id: record.chain_id })
      else
        record.revoke!
      end
    end
    head :ok
  end
end
