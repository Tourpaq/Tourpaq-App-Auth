# A user's signed-in browser extensions (SPECS.md §10.6): one per token chain, represented by the
# chain's current refresh token (active and not yet replaced). Listed on the profile and on the
# admin's user page, where they can be signed out (the whole chain is revoked, audited oauth.revoked).
#
#   ExtensionSignIns.for(user)              # [OauthToken] current refresh tokens, newest first
#   ExtensionSignIns.find_for(user, id)     # one of them (RecordNotFound otherwise)
#   ExtensionSignIns.revoke!(token, by: "user" | "admin")
module ExtensionSignIns
  module_function

  def scope(user) = user.oauth_tokens.refresh.active.where(replaced_by_id: nil).includes(client: :app)

  def for(user) = scope(user).order(created_at: :desc).to_a

  def find_for(user, id) = scope(user).find(id)

  def revoke!(token, by:)
    OauthToken.transaction do
      token.revoke_chain!
      AuditEvent.record("oauth.revoked", subject: token.user, app: token.client.app,
                        data: { client_id: token.client.client_id, chain_id: token.chain_id, by: by })
    end
  end

  # When the extension signed in: the chain's first token.
  def signed_in_at(token) = OauthToken.where(chain_id: token.chain_id).minimum(:created_at) || token.created_at
end
