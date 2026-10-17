# Entra in tests: OmniAuth's test mode with the fake identity provider's auth hash (the same shape
# as the real strategy's), and a fake JWKS for the ID-token verifier.
module EntraHelpers
  def entra_tenant_id = Rails.configuration.x.auth.entra_tenant_id

  # The next POST /auth/entra_id signs in as this Entra account. Claims can be overridden or
  # removed (nil): mock_entra(email: "x@tourpaq.com", tid: "other-tenant", email_claim: …).
  def mock_entra(email:, name: nil, **claims)
    OmniAuth.config.mock_auth[:entra_id] = FakeIdentity.auth_hash(email: email, name: name, **claims)
  end

  # The next sign-in fails inside OmniAuth with this error type (e.g. :invalid_credentials).
  def mock_entra_failure(type = :invalid_credentials)
    OmniAuth.config.mock_auth[:entra_id] = type
  end

  # A signing key plus a JWKS with it, for OmniAuth::EntraIdToken tests.
  class FakeEntraKeys
    attr_reader :key, :kid, :fetches

    def initialize
      @key = OpenSSL::PKey::RSA.generate(2048)
      @kid = "entra-key-1"
      @fetches = 0
    end

    def call(_url)
      @fetches += 1
      { "keys" => [ JWT::JWK.new(key.public_key, kid: kid).export.transform_keys(&:to_s) ] }
    end

    def id_token(claims = {}, key: self.key, kid: self.kid)
      JWT.encode(claims.compact.stringify_keys, key, "RS256", { kid: kid })
    end
  end
end
