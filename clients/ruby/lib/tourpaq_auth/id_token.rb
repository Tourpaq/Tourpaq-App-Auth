module TourpaqAuth
  # Who signed in, from a verified ID token (SPECS.md §7.3).
  #   sub                   the auth app's stable subject (store it next to the email)
  #   role                  the user's role in this app (the configured role claim), or nil; always nil for a
  #                         permission app (SPECS.md §23.2), whose role claim is a list
  #   roles                 the role names: a permission app's list, else [role] (or [])
  #   permissions           a permission app's permissions (the sorted union, "*" = everything), else []
  #   sessions_valid_after  Time or nil: end app sessions that started before it
  #   authenticated_at      Time of the auth app's sign-in (auth_time), or nil
  #   claims                all claims, string keys
  # permission?(key) and role?(name) come from TourpaqAuth::Permissions.
  Login = Data.define(:sub, :email, :name, :role, :sessions_valid_after, :authenticated_at, :claims, :roles, :permissions) do
    include Permissions

    # roles and permissions may be left out (single-role apps, and tests written before them).
    def initialize(roles: nil, permissions: nil, **fields)
      super(**fields, roles: Permissions.role_list(roles, fields[:role]), permissions: Permissions.list(permissions))
    end

    def email_verified? = claims["email_verified"] != false
  end

  # Verifies an ID token from the auth app: signature against the JWKS (fetched again once for an
  # unknown key id), issuer, audience, expiry, issued-at and the nonce we sent.
  module IdToken
    ALGORITHMS = %w[RS256 RS384 RS512 ES256 ES384 PS256].freeze
    LEEWAY = 60

    module_function

    def verify(token, nonce:)
      config = TourpaqAuth.config
      loader = ->(options) { options[:kid_not_found] ? Client.jwks(refresh: true) : Client.jwks }
      claims, = JWT.decode(token.to_s, nil, true, algorithms: ALGORITHMS, jwks: loader,
                           iss: config.issuer, verify_iss: true, aud: config.client_id, verify_aud: true,
                           verify_expiration: true, verify_iat: true, leeway: LEEWAY)
      unless nonce.to_s != "" && TourpaqAuth.secure_compare(claims["nonce"].to_s, nonce.to_s)
        raise LoginError, "The ID token's nonce does not match this login"
      end
      raise LoginError, "The ID token has no subject" if claims["sub"].to_s.empty?
      raise LoginError, "The ID token has no expiry" unless claims["exp"]
      login_from(claims)
    rescue JWT::DecodeError => e
      raise LoginError, "The ID token is not valid: #{e.message}"
    end

    def login_from(claims)
      config = TourpaqAuth.config
      email = (claims["email"].to_s.empty? ? claims["preferred_username"] : claims["email"]).to_s.strip.downcase
      raw = claims.key?(config.role_claim) ? claims[config.role_claim] : claims[config.roles_claim]
      # A permission app's role claim is a list (SPECS.md §23.2): then there is no single role.
      role, roles = raw.is_a?(Array) ? [ nil, raw ] : [ role_from(raw), nil ]
      Login.new(sub: claims["sub"].to_s, email: email.empty? ? nil : email, name: claims["name"], role: role, roles: roles,
                permissions: Array(claims[config.permissions_claim]),
                sessions_valid_after: time_or_nil(claims["sessions_valid_after"]),
                authenticated_at: time_or_nil(claims["auth_time"]), claims: claims.freeze)
    end

    # One role per app (SPECS.md §1) in a single-role app.
    def role_from(value)
      value.nil? || value.to_s.strip.empty? ? nil : value.to_s.strip
    end

    def time_or_nil(value)
      case value
      when nil, "" then nil
      when Integer, Float then Time.at(value).utc
      when /\A\d+\z/ then Time.at(value.to_i).utc
      else Time.iso8601(value.to_s).utc
      end
    rescue ArgumentError
      nil
    end
  end
end
