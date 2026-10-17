# Client for Tourpaq Auth (auth.app.journeybooking.eu, the issuer), SPECS.md §13 of the auth app:
#
# - TourpaqAuth::Client / TourpaqAuth::IdToken: OIDC login (discovery, PKCE, state, nonce, ID token)
# - TourpaqAuth::Access: "does this user still have access, with which role?" and the members list (§8)
# - TourpaqAuth::Tokens: personal/extension token introspection (§9, §10)
# - TourpaqAuth::Catalogue: a permission app pushes its permission catalogue (§23.2)
# - TourpaqAuth::Permissions: roles / permissions / permission? on the results above (§23.2)
# - TourpaqAuth::Rails::AccessCheck and ::BearerToken: controller concerns (loaded on first use)
# - TourpaqAuth::TestSupport::FakeProvider: a fake auth app for tests (require "tourpaq_auth/test_support")
require "digest"
require "openssl"
require "securerandom"
require "time"
require "jwt"

require_relative "tourpaq_auth/version"
require_relative "tourpaq_auth/errors"
require_relative "tourpaq_auth/memory_store"
require_relative "tourpaq_auth/configuration"
require_relative "tourpaq_auth/http"
require_relative "tourpaq_auth/permissions"
require_relative "tourpaq_auth/api"
require_relative "tourpaq_auth/client"
require_relative "tourpaq_auth/id_token"
require_relative "tourpaq_auth/access"
require_relative "tourpaq_auth/tokens"
require_relative "tourpaq_auth/catalogue"

module TourpaqAuth
  # The Rails integration. Autoloaded, so apps without Rails never load ActiveSupport through the gem.
  # (Inside TourpaqAuth, `Rails` means this module: the gem's own code says ::Rails for the framework.)
  module Rails
    autoload :AccessCheck, "tourpaq_auth/rails/access_check"
    autoload :BearerToken, "tourpaq_auth/rails/bearer_token"
  end

  class << self
    # Reads the configuration from the environment (LOGIN_*), then lets the block override it.
    # Clears the cached discovery document and keys.
    def configure(env = ENV)
      configuration = Configuration.new(env)
      yield configuration if block_given?
      self.config = configuration
    end

    # The configuration; read from ENV on first use when configure was never called.
    def config = @config ||= Configuration.new(ENV)

    def config=(configuration)
      @config = configuration
      Client.reset!
      configuration
    end

    def enabled? = config.enabled?

    def now = config.clock.call

    # Forgets the in-process discovery and JWKS cache (the configured cache is the app's to clear).
    def reset! = Client.reset!

    # Hex SHA-256: how tokens are named in cache keys, never the token itself.
    def digest(value) = Digest::SHA256.hexdigest(value.to_s)

    # Constant-time string comparison (lengths may differ).
    def secure_compare(a, b)
      return false if a.nil? || b.nil?
      OpenSSL.fixed_length_secure_compare(Digest::SHA256.digest(a.to_s), Digest::SHA256.digest(b.to_s))
    end

    def log(level, message)
      config.logger&.public_send(level, "[tourpaq_auth] #{message}")
    rescue StandardError
      nil
    end
  end
end
