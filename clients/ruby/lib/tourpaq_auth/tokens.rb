module TourpaqAuth
  # Token introspection (SPECS.md §9.2, §10): is this personal (tpa_…) or extension (tpx_…) token valid,
  # for whom, with which scope and role? Answers are cached for 60 seconds under the token's SHA-256;
  # the token itself is never stored, cached or logged.
  module Tokens
    FIELDS = %w[active token_type sub email name scope role exp app client_id token_name roles permissions].freeze
    MAX_LENGTH = 4096

    # The effective right is the scope capped by the role, and each app decides what its roles may do:
    # e.g. `result.read_write? && %w[responder editor admin].include?(result.role)`. A permission app (SPECS.md
    # §23.2, §23.3) has its own scopes (the Dashboard: public < all; scope?("all")) and gets role nil, the role
    # names in `roles` and the permissions in `permissions` (permission?(key) understands "*").
    Result = Data.define(:active, :token_type, :sub, :email, :name, :scope, :role, :exp, :app, :client_id, :token_name,
                         :roles, :permissions) do
      include Permissions

      def initialize(roles: nil, permissions: nil, **fields)
        super(**fields, roles: Permissions.role_list(roles, fields[:role]), permissions: Permissions.list(permissions))
      end

      def active? = active == true
      def read_write? = active? && scope == "read_write"
      def read? = active? && %w[read read_write].include?(scope)
      # Is the token's scope one of these (e.g. scope?("all"))?
      def scope?(*names) = active? && names.flatten.map(&:to_s).include?(scope.to_s)
    end

    INACTIVE = Result.new(active: false, token_type: nil, sub: nil, email: nil, name: nil, scope: nil, role: nil,
                          exp: nil, app: nil, client_id: nil, token_name: nil, roles: [], permissions: [])

    module_function

    # Returns a Result (INACTIVE for an unknown, expired, revoked or foreign token). Raises
    # TourpaqAuth::Unavailable when the auth app cannot be reached and nothing is cached, and
    # TourpaqAuth::Error when it refuses the app's own credentials.
    def introspect(token)
      token = token.to_s.strip
      return INACTIVE if token.empty? || token.length > MAX_LENGTH

      config = TourpaqAuth.config
      key = cache_key(token)
      cached = config.cache.read(key)
      return build(cached) if cached.is_a?(Hash)

      status, body = Api.call(:post, "/oauth/introspect", form: { token: token })
      Api.refused!(status, body) unless status == 200
      json = Http.parse_json(body)
      raise Error, "The introspection answer is not an object" unless json.is_a?(Hash)

      entry = json.slice(*FIELDS)
      entry = { "active" => false } unless entry["active"] == true
      ttl = config.introspection_cache_seconds
      if entry["active"] && entry["exp"]
        remaining = entry["exp"].to_i - TourpaqAuth.now.to_i
        return INACTIVE if remaining <= 0
        ttl = [ ttl, remaining ].min
      end
      config.cache.write(key, entry, expires_in: ttl)
      build(entry)
    end

    # Is an answer for this token cached (so introspect will not call the auth app)? Lets an app spend
    # its own per-address budget only on tokens that would cost an introspection.
    def cached?(token)
      token = token.to_s.strip
      return false if token.empty? || token.length > MAX_LENGTH
      TourpaqAuth.config.cache.read(cache_key(token)).is_a?(Hash)
    end

    # Forgets a cached answer (e.g. after the app learns the token was revoked).
    def forget(token) = TourpaqAuth.config.cache.delete(cache_key(token.to_s.strip))

    def cache_key(token) = "tourpaq_auth:introspect:#{TourpaqAuth.config.client_id}:#{TourpaqAuth.digest(token)}"

    def build(entry)
      entry = entry.transform_keys(&:to_s)
      return INACTIVE unless entry["active"] == true
      exp = IdToken.time_or_nil(entry["exp"])
      return INACTIVE if exp && exp <= TourpaqAuth.now
      Result.new(active: true, token_type: entry["token_type"], sub: entry["sub"], email: entry["email"], name: entry["name"],
                 scope: entry["scope"], role: entry["role"], exp: exp, app: entry["app"], client_id: entry["client_id"],
                 token_name: entry["token_name"], roles: entry.key?("roles") ? entry["roles"] : nil, permissions: entry["permissions"])
    end
  end
end
