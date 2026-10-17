# The index extension's bearer token on the INDEX host's /api/v1/index (SPECS.md §10, §24.3): an access token
# tpx_index_… issued to an extension client of the auth App "index" (index-extension). The index API is this same
# app, so it checks the token against the token store in-process, with exactly the rules of POST /oauth/introspect
# (Oidc::Introspection.extension): known, an access token of an active extension client of that app, not revoked,
# not expired, not retired, and its user still active with access to the app. last_used_at is recorded as there.
#
#   Index::ExtensionToken.user_for(plain)   # the User, or nil
module Index::ExtensionToken
  module_function

  def user_for(plain)
    plain = plain.to_s
    return if plain.length > 512 || !plain.start_with?("#{OauthToken::ACCESS_PREFIX}#{Index::APP_SLUG}_")
    token = OauthToken.access.includes(client: :app).find_by(token_digest: HashedToken.digest(plain))
    return unless token&.client&.app&.slug == Index::APP_SLUG
    answer = Oidc::Introspection.extension(token.client, plain)
    return unless answer["active"] && answer["app"] == Index::APP_SLUG
    User.active.find_by(sub: answer["sub"])
  end
end
