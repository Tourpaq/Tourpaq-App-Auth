# One of our own ID tokens that does not verify: bad signature, issuer, audience, expiry or nonce
# (Oidc::IdToken.verify, the admin host's callback, id_token_hint at logout).
module Oidc
  class InvalidToken < StandardError; end
end
