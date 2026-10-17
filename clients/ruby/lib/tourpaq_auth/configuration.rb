require "uri"

module TourpaqAuth
  # Settings, read from the environment by TourpaqAuth.configure (README "Configuration"). Anything can
  # be overridden in the block:
  #
  #   TourpaqAuth.configure do |config|
  #     config.redirect_uri = "#{app_url}/sso/callback"
  #     config.grace_hours = 72
  #   end
  class Configuration
    DEFAULT_SCOPES = "openid email profile".freeze

    attr_accessor :issuer, :internal_url, :client_id, :client_secret, :scopes, :redirect_uri,
                  :access_cache_seconds, :grace_hours, :introspection_cache_seconds, :http_timeout
    attr_writer :role_claim, :permissions_claim, :cache, :http, :logger, :clock

    def initialize(env = ENV)
      @issuer = env["LOGIN_ISSUER"].to_s.strip.chomp("/")
      @issuer = nil if @issuer.empty?
      @internal_url = presence(env["LOGIN_INTERNAL_URL"])&.chomp("/")
      @client_id = presence(env["LOGIN_CLIENT_ID"])
      @client_secret = presence(env["LOGIN_CLIENT_SECRET"])
      @scopes = presence(env["LOGIN_SCOPES"]) || DEFAULT_SCOPES
      @role_claim = presence(env["LOGIN_ROLE_CLAIM"])
      @permissions_claim = presence(env["LOGIN_PERMISSIONS_CLAIM"])
      @redirect_uri = presence(env["LOGIN_REDIRECT_URI"])
      @access_cache_seconds = integer(env["LOGIN_ACCESS_CACHE_SECONDS"], 300)
      @grace_hours = number(env["LOGIN_GRACE_HOURS"], 24)
      @introspection_cache_seconds = 60
      @http_timeout = 5
    end

    # On only when the issuer, client id and client secret are all set.
    def enabled? = !issuer.nil? && !client_id.nil? && !client_secret.nil?

    # The ID-token claim with the user's role in this app. LOGIN_ROLE_CLAIM, or else derived from the
    # client id like the auth app derives it from the app slug: "irm-web" → "irm_role" (SPECS.md §5.1).
    def role_claim
      @role_claim || (app_prefix && "#{app_prefix}_role")
    end

    # A permission app's role list (SPECS.md §23.2) when LOGIN_ROLE_CLAIM is not set: "dashboard-web" →
    # "dashboard_roles". Read when the role claim itself is absent from the ID token.
    def roles_claim = app_prefix && "#{app_prefix}_roles"

    # The ID-token claim with a permission app's permissions (SPECS.md §23.2). LOGIN_PERMISSIONS_CLAIM, or derived
    # from the client id: "dashboard-web" → "dashboard_permissions".
    def permissions_claim
      @permissions_claim || (app_prefix && "#{app_prefix}_permissions")
    end

    # "irm-web" → "irm", "azure-cost-web" → "azure_cost": the app's slug as the auth app writes it in claim names.
    def app_prefix = client_id && client_id.sub(/-web\z/, "").tr("-", "_")

    def grace_seconds = (grace_hours.to_f * 3600).to_i

    # The cache for access answers and introspection results: anything with read, write(key, value,
    # expires_in:) and delete. Rails.cache when the app has one, else a per-process memory store.
    def cache
      @cache ||= if defined?(::Rails) && ::Rails.respond_to?(:cache) && ::Rails.cache
        ::Rails.cache
      else
        MemoryStore.new
      end
    end

    # The HTTP seam: a callable (method, url, form:, headers:, timeout:) → [status, body, headers].
    # TourpaqAuth::TestSupport::FakeProvider is one.
    def http = @http ||= Http.method(:request)

    def logger
      return @logger if defined?(@logger)
      defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
    end

    # Returns the current time; tests may replace it. Time.now is what ActiveSupport's travel_to stubs.
    def clock = @clock ||= -> { Time.now }

    # A URL the browser is sent to, or that names the issuer: always under LOGIN_ISSUER.
    def endpoint(path) = "#{issuer}#{path}"

    # A server-to-server URL (discovery, JWKS, token, userinfo, introspection, the access API, the catalogue):
    # under LOGIN_INTERNAL_URL when it is set (e.g. http://auth:3050 on a shared Docker network, or
    # http://host.docker.internal:3050 in local testing), else under LOGIN_ISSUER (SPECS.md §24.1).
    def backchannel_endpoint(path) = "#{internal_url || issuer}#{path}"

    # A URL from the discovery document, moved to LOGIN_INTERNAL_URL's origin when that is set; unchanged otherwise.
    # The auth app writes every URL under its issuer, so the issuer prefix is what is swapped; a URL elsewhere
    # keeps its path and query on the internal origin.
    def backchannel_url(url)
      return url if internal_url.nil? || url.nil?
      url = url.to_s
      return "#{internal_url}#{url.delete_prefix(issuer)}" if issuer && (url == issuer || url.start_with?("#{issuer}/"))
      uri = URI(url)
      "#{internal_url}#{uri.path}#{"?#{uri.query}" if uri.query}"
    rescue URI::InvalidURIError
      url
    end

    private

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end

    def integer(value, default) = presence(value) ? Integer(value, 10) : default
    def number(value, default) = presence(value) ? Float(value) : default
  end
end
