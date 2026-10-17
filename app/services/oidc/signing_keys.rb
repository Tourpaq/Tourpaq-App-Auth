# The OIDC provider's signing keys (SPECS.md §7.3, §14): RS256, from OIDC_SIGNING_KEY (current, signs)
# and OIDC_PREVIOUS_SIGNING_KEY (still published in the JWKS during a rotation). The kid is the key's
# RFC 7638 thumbprint, so it changes exactly when the key does and needs no configuration.
#
#   Oidc::SigningKeys.current   # JWT::JWK with the private key (signs ID tokens)
#   Oidc::SigningKeys.published # [JWT::JWK] public keys: current, then previous
#   Oidc::SigningKeys.jwks      # { keys: [...] } for GET /oauth/jwks
#   Oidc::SigningKeys.verifier_set # JWT::JWK::Set for verifying our own tokens
#
# Production refuses to boot without OIDC_SIGNING_KEY (config/initializers/oidc.rb). Development
# keeps a generated key in tmp/oidc_dev_signing_key.pem, so a restart does not invalidate tokens;
# tests generate one per process.
module Oidc
  module SigningKeys
    class MissingKey < StandardError; end

    MIN_BITS = 2048
    ALGORITHM = "RS256".freeze
    DEV_KEY_PATH = "tmp/oidc_dev_signing_key.pem".freeze

    @cache = Concurrent::Map.new

    module_function

    def current = jwk(current_pem)

    def previous
      pem = config.oidc_previous_signing_key
      pem.present? ? jwk(pem) : nil
    end

    def published = [ current, previous ].compact.uniq(&:kid).map { public_jwk(_1) }

    def jwks = { keys: published.map(&:export) }

    def verifier_set = JWT::JWK::Set.new(published)

    def sign(payload)
      key = current
      JWT.encode(payload, key.signing_key, ALGORITHM, { kid: key.kid, typ: "JWT" })
    end

    # --- internals -------------------------------------------------------------------------------

    def config = Rails.configuration.x.auth

    def current_pem
      config.oidc_signing_key.presence || fallback_pem
    end

    def jwk(pem)
      @cache.compute_if_absent(Digest::SHA256.hexdigest(pem)) do
        key = OpenSSL::PKey::RSA.new(pem)
        raise MissingKey, "the OIDC signing key must be a private RSA key" unless key.private?
        raise MissingKey, "the OIDC signing key must have at least #{MIN_BITS} bits" if key.n.num_bits < MIN_BITS
        JWT::JWK.new(key, { use: "sig", alg: ALGORITHM }, kid_generator: JWT::JWK::Thumbprint)
      end
    rescue OpenSSL::PKey::PKeyError => e
      raise MissingKey, "the OIDC signing key is not a PEM RSA key (#{e.class})"
    end

    def public_jwk(key) = JWT::JWK.new(key.verify_key, { use: "sig", alg: ALGORITHM }, kid_generator: JWT::JWK::Thumbprint)

    def fallback_pem
      if Rails.env.production?
        raise MissingKey, "Set OIDC_SIGNING_KEY (an RSA private key, PEM; see .env.example)"
      elsif Rails.env.test?
        @test_pem ||= OpenSSL::PKey::RSA.generate(MIN_BITS).to_pem
      else
        path = Rails.root.join(DEV_KEY_PATH)
        File.write(path, OpenSSL::PKey::RSA.generate(MIN_BITS).to_pem, perm: 0o600) unless File.exist?(path)
        File.read(path)
      end
    end
  end
end
