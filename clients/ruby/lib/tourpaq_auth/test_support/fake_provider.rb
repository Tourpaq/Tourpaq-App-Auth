require "json"
require "uri"

module TourpaqAuth
  module TestSupport
    # A fake Tourpaq Auth for tests, answering through the gem's HTTP seam (no network): discovery, JWKS,
    # the token endpoint, /api/v1/access(/:sub), /oauth/introspect and PUT /api/v1/catalogue. It signs ID tokens
    # with its own RSA key, checks client_secret_basic and PKCE, and keeps users, tokens and the catalogue in memory.
    #
    # A permission app (SPECS.md §23.2, §23.3), like the Dashboard:
    #
    #   provider = FakeProvider.new(client_id: "dashboard-web", multiple_roles: true, token_scopes: %w[public all])
    #   sub = provider.add_user(email: "x@tourpaq.com", roles: [ "Support" ], permissions: %w[module:customers:view])
    #   provider.set_roles(sub, [ "Administrators" ], permissions: [ "*" ])
    #   provider.issue_token(sub: sub, scope: "all")
    #   provider.catalogue                      # the last pushed catalogue (hashes: key, label, group)
    #
    #   provider = TourpaqAuth::TestSupport::FakeProvider.new(client_id: "irm-web")
    #   provider.install!                       # configures TourpaqAuth against it (memory cache)
    #   sub = provider.add_user(email: "jjr@tourpaq.com", role: "responder")
    #   provider.authorize(authorization_url, sub: sub)   # → { "code" => …, "state" => … } for the callback
    #   token = provider.issue_token(sub: sub, scope: "read_write")
    #   provider.remove_access(sub); provider.sign_out_everywhere(sub); provider.reachable = false
    #   provider.client_disabled = true         # 401 invalid_client, as for a disabled app, client or secret
    #   provider.catalogue_status = 400         # refuse the next catalogue pushes
    #
    # The back-channel through another base URL (LOGIN_INTERNAL_URL, SPECS.md §24.1), as on a shared Docker network:
    #
    #   provider = FakeProvider.new(internal_url: "http://auth:3050")   # answers there too; env sets LOGIN_INTERNAL_URL
    #   provider.requests.map { _1[:url] }                              # which base each call used
    class FakeProvider
      ISSUER = "https://auth.example.test".freeze
      CLIENT_ID = "test-web".freeze
      CLIENT_SECRET = "test-client-secret".freeze

      attr_reader :issuer, :internal_url, :client_id, :client_secret, :app, :users, :requests, :token_requests, :kid, :catalogue, :catalogue_pushes
      attr_accessor :nonce, :claims, :reachable, :token_status, :access_status, :introspect_status, :members_status,
                    :signing_key, :access_max_age, :jwks_fetches, :role_claim, :permissions_claim, :client_disabled,
                    :multiple_roles, :token_scopes, :catalogue_status

      def initialize(issuer: ISSUER, client_id: CLIENT_ID, client_secret: CLIENT_SECRET, app: nil, role_claim: nil,
                     multiple_roles: false, permissions_claim: nil, token_scopes: %w[read read_write], internal_url: nil)
        @issuer = issuer.chomp("/")
        @internal_url = internal_url&.chomp("/")
        @client_id = client_id
        @client_secret = client_secret
        @app = app || client_id.sub(/-web\z/, "")
        @multiple_roles = multiple_roles
        @role_claim = role_claim || "#{@app.tr('-', '_')}_#{multiple_roles ? 'roles' : 'role'}"
        @permissions_claim = permissions_claim || "#{@app.tr('-', '_')}_permissions"
        @token_scopes = token_scopes
        @catalogue = nil
        @catalogue_pushes = 0
        @signing_key = OpenSSL::PKey::RSA.generate(2048)
        @published_keys = { "key-1" => @signing_key }
        @kid = "key-1"
        @claims = {}
        @reachable = true
        @token_status = 200
        @access_max_age = 300
        @users = {}
        @tokens = {}
        @codes = {}
        @requests = []
        @token_requests = []
        @jwks_fetches = 0
      end

      # The LOGIN_* environment for this provider.
      def env(extra = {})
        { "LOGIN_ISSUER" => issuer, "LOGIN_CLIENT_ID" => client_id, "LOGIN_CLIENT_SECRET" => client_secret,
          "LOGIN_ROLE_CLAIM" => role_claim, "LOGIN_PERMISSIONS_CLAIM" => permissions_claim,
          "LOGIN_INTERNAL_URL" => internal_url }.compact.merge(extra)
      end

      # Configures TourpaqAuth against this provider, with a fresh memory cache. Returns the configuration.
      def install!(env_overrides = {}, &block)
        TourpaqAuth.configure(env(env_overrides)) do |config|
          config.http = self
          config.cache = TourpaqAuth::MemoryStore.new
          config.redirect_uri ||= "http://app.example.test/sso/callback"
          block&.call(config)
        end
      end

      # --- users and access (SPECS.md §8) ------------------------------------------------------------

      # A single-role app's user has `role`; a permission app's (multiple_roles) has `roles` (default [role]) and
      # `permissions`.
      def add_user(sub: SecureRandom.uuid, email:, name: nil, role: "viewer", roles: nil, permissions: [], sessions_valid_after: nil)
        @users[sub] = { "sub" => sub, "email" => email.downcase, "name" => name || email.split("@").first.capitalize,
                        "role" => role, "roles" => roles || [ role ].compact, "permissions" => Array(permissions).sort,
                        "disabled" => false, "sessions_valid_after" => sessions_valid_after && epoch_ceil(sessions_valid_after) }
        sub
      end

      def set_role(sub, role)
        user = user!(sub)
        user["role"] = role
        user["roles"] = [ role ].compact
      end

      # A permission app: the user's role names and the union of their permissions.
      def set_roles(sub, roles, permissions: user!(sub)["permissions"])
        user = user!(sub)
        user["roles"] = Array(roles)
        user["permissions"] = Array(permissions).sort
      end

      def set_permissions(sub, permissions) = user!(sub)["permissions"] = Array(permissions).sort

      def remove_access(sub)
        set_role(sub, nil)
        user!(sub)["permissions"] = []
      end

      def disable_user(sub)
        user!(sub)["disabled"] = true
      end

      def enable_user(sub)
        user!(sub)["disabled"] = false
      end

      # As the auth app hands it out: Unix seconds rounded up, so an app session that started in the same second
      # (apps keep whole seconds) is ended too.
      def sign_out_everywhere(sub, at: TourpaqAuth.now)
        user!(sub)["sessions_valid_after"] = epoch_ceil(at)
      end

      def epoch_ceil(time) = time.to_r.ceil

      def active?(sub)
        user = @users[sub]
        return false unless user && !user["disabled"]
        multiple_roles ? user["roles"].any? : !user["role"].nil?
      end

      # --- tokens (SPECS.md §9, §10) -----------------------------------------------------------------

      # Issues a personal (tpa_) or extension (tpx_) token for this app; returns the token.
      # scope: one of token_scopes (default its lowest); an extension token gets the highest, as the auth app gives it.
      def issue_token(sub:, scope: nil, token_type: "personal", expires_in: 90 * 86_400, name: "Test token", app: self.app)
        scope ||= token_type == "extension" ? token_scopes.last : token_scopes.first
        raise ArgumentError, "scope #{scope.inspect} is not one of #{token_scopes.inspect}" unless token_scopes.include?(scope)
        prefix = token_type == "extension" ? "tpx" : "tpa"
        token = "#{prefix}_#{app}_#{SecureRandom.urlsafe_base64(32)}"
        @tokens[token] = { "sub" => sub, "scope" => scope, "token_type" => token_type, "app" => app, "token_name" => name,
                           "exp" => TourpaqAuth.now.to_i + expires_in, "revoked" => false }
        token
      end

      def revoke_token(token)
        @tokens.fetch(token)["revoked"] = true
      end

      # How many times a token was introspected (the fake knows tokens; the gem's cache must not).
      def introspections(token = nil)
        calls = requests.select { _1[:path] == "/oauth/introspect" }
        token ? calls.count { _1[:form] && _1[:form][:token] == token } : calls.size
      end

      # --- login (SPECS.md §7) -----------------------------------------------------------------------

      # Plays the browser at /oauth/authorize: reads the app's authorization URL, remembers its nonce,
      # PKCE challenge and redirect URI, and returns the callback parameters ("code", "state"). The ID
      # token is for `sub` (a user added with add_user) or carries `claims`.
      def authorize(authorization_url, sub: nil, claims: {})
        query = URI.decode_www_form(URI(authorization_url).query.to_s).to_h
        raise ArgumentError, "client_id #{query['client_id'].inspect} is not #{client_id}" unless query["client_id"] == client_id
        raise ArgumentError, "PKCE S256 is required" unless query["code_challenge_method"] == "S256" && query["code_challenge"]
        user_claims = sub ? claims_for(sub) : {}
        code = SecureRandom.urlsafe_base64(24)
        @codes[code] = { "nonce" => query["nonce"], "challenge" => query["code_challenge"], "redirect_uri" => query["redirect_uri"],
                         "claims" => user_claims.merge(claims.transform_keys(&:to_s)) }
        self.nonce = query["nonce"]
        { "code" => code, "state" => query["state"] }
      end

      # Publishes a new key under a new key id and signs with it from now on (the old one stays published).
      def rotate_key!(keep_old: true)
        @signing_key = OpenSSL::PKey::RSA.generate(2048)
        @kid = "key-#{SecureRandom.hex(3)}"
        @published_keys = keep_old ? @published_keys.merge(@kid => @signing_key) : { @kid => @signing_key }
      end

      # Signs with a key that is not the published one, under the same key id: a forged token.
      def forge_with_other_key!
        @signing_key = OpenSSL::PKey::RSA.generate(2048)
      end

      def id_token(overrides = {})
        now = TourpaqAuth.now.to_i
        payload = { "iss" => issuer, "aud" => client_id, "sub" => "sub-123", "iat" => now, "exp" => now + 300,
                    "auth_time" => now, "nonce" => nonce, "email" => "someone@example.test", "email_verified" => true,
                    "name" => "Someone" }
        payload = payload.merge(claims.transform_keys(&:to_s)).merge(overrides.transform_keys(&:to_s)).reject { |_, v| v.nil? }
        JWT.encode(payload, signing_key, "RS256", { kid: kid })
      end

      # --- the HTTP seam -----------------------------------------------------------------------------

      def call(method, url, form: nil, headers: {}, timeout: 5, body: nil)
        uri = URI(url)
        requests << { method: method, url: url, path: uri.path, form: form, headers: headers, body: body }
        raise Errno::ECONNREFUSED, url unless reachable
        return json(404, error: "not_found") unless url.start_with?("#{issuer}/") || (internal_url && url.start_with?("#{internal_url}/"))

        case [ method, uri.path ]
        in [ :get, "/.well-known/openid-configuration" ] then json(200, discovery)
        in [ :get, "/oauth/jwks" ]
          @jwks_fetches += 1
          json(200, keys: @published_keys.map { |id, key| JWT::JWK.new(key.public_key, kid: id).export })
        in [ :post, "/oauth/token" ] then token_endpoint(form || {}, headers)
        in [ :get, "/api/v1/access" ] then authenticated(headers) { members_endpoint(headers) }
        in [ :get, %r{\A/api/v1/access/([^/]+)\z} ]
          authenticated(headers) { access_endpoint(URI.decode_www_form_component(uri.path.split("/").last)) }
        in [ :post, "/oauth/introspect" ] then authenticated(headers) { introspect_endpoint(form || {}) }
        in [ :put, "/api/v1/catalogue" ] then authenticated(headers) { catalogue_endpoint(body) }
        else json(404, error: "not_found")
        end
      end

      def discovery
        { issuer: issuer, authorization_endpoint: "#{issuer}/oauth/authorize", token_endpoint: "#{issuer}/oauth/token",
          jwks_uri: "#{issuer}/oauth/jwks", userinfo_endpoint: "#{issuer}/oauth/userinfo",
          introspection_endpoint: "#{issuer}/oauth/introspect", revocation_endpoint: "#{issuer}/oauth/revoke",
          end_session_endpoint: "#{issuer}/oauth/logout", response_types_supported: [ "code" ],
          id_token_signing_alg_values_supported: [ "RS256" ], code_challenge_methods_supported: [ "S256" ],
          token_endpoint_auth_methods_supported: %w[client_secret_basic client_secret_post] }
      end

      private

      def user!(sub) = @users.fetch(sub) { raise ArgumentError, "unknown user #{sub}" }

      def claims_for(sub)
        user = user!(sub)
        claims = { "sub" => sub, "email" => user["email"], "name" => user["name"], "preferred_username" => user["email"],
                   "sessions_valid_after" => user["sessions_valid_after"] }
        if multiple_roles
          claims.merge(role_claim => user["roles"], permissions_claim => user["permissions"])
        else
          claims.merge(role_claim => user["role"])
        end
      end

      # What the auth app adds for a permission app (SPECS.md §23.2): role null, roles and permissions.
      def access_fields(user, active)
        return { role: active ? user["role"] : nil } unless multiple_roles
        { role: nil, roles: active ? user["roles"] : [], permissions: active ? user["permissions"] : [] }
      end

      def json(status, body, headers = {})
        [ status, body.to_json, { "Content-Type" => "application/json" }.merge(headers) ]
      end

      def client_authenticated?(headers)
        return false if client_disabled
        header = headers.find { |k, _| k.to_s.casecmp?("Authorization") }&.last.to_s
        header == TourpaqAuth::Http.basic_auth(client_id, client_secret)
      end

      def authenticated(headers)
        return json(401, error: "invalid_client") unless client_authenticated?(headers)
        yield
      end

      def token_endpoint(form, headers)
        form = form.transform_keys(&:to_sym)
        token_requests << { form: form, headers: headers }
        return json(401, error: "invalid_client") unless client_authenticated?(headers)
        return json(token_status, error: "invalid_grant", error_description: "Code expired") unless token_status == 200
        return json(400, error: "unsupported_grant_type") unless form[:grant_type] == "authorization_code"

        issued = @codes.delete(form[:code].to_s)
        if issued
          verifier_ok = TourpaqAuth::Client.pkce_challenge(form[:code_verifier].to_s) == issued["challenge"]
          return json(400, error: "invalid_grant", error_description: "PKCE verification failed") unless verifier_ok
          return json(400, error: "invalid_grant", error_description: "redirect_uri mismatch") unless form[:redirect_uri] == issued["redirect_uri"]
          token = id_token(issued["claims"].merge("nonce" => issued["nonce"]))
        else
          token = id_token # a code from a test that skipped authorize: the current nonce and claims
        end
        json(200, access_token: "fake-access-token", token_type: "Bearer", expires_in: 300, id_token: token)
      end

      def access_endpoint(sub)
        return json(access_status, error: "server_error") if access_status
        user = @users[sub]
        body = { sub: sub, active: active?(sub), **access_fields(user || {}, active?(sub)), email: user&.dig("email"),
                 name: user&.dig("name"), sessions_valid_after: user&.dig("sessions_valid_after"),
                 checked_at: Time.at(TourpaqAuth.now.to_i).utc.iso8601 }
        json(200, body, "Cache-Control" => "private, max-age=#{access_max_age}")
      end

      def members_endpoint(headers)
        return json(members_status, error: "server_error") if members_status
        members = @users.values.select { active?(_1["sub"]) }.map do |user|
          user.slice("sub", "email", "name", "sessions_valid_after").merge(access_fields(user, true).transform_keys(&:to_s))
        end
        body = { app: app, members: members }.to_json
        etag = %(W/"#{Digest::SHA256.hexdigest(body)[0, 32]}")
        if_none_match = headers.find { |k, _| k.to_s.casecmp?("If-None-Match") }&.last
        return [ 304, "", { "ETag" => etag } ] if if_none_match == etag
        [ 200, body, { "Content-Type" => "application/json", "ETag" => etag } ]
      end

      def introspect_endpoint(form)
        return json(introspect_status, error: "server_error") if introspect_status
        form = form.transform_keys(&:to_sym)
        token = @tokens[form[:token].to_s]
        user = token && @users[token["sub"]]
        valid = token && !token["revoked"] && token["exp"] > TourpaqAuth.now.to_i && token["app"] == app && active?(token["sub"])
        return json(200, active: false) unless valid
        json(200, active: true, token_type: token["token_type"], client_id: client_id, app: app, sub: token["sub"],
                  email: user["email"], name: user["name"], scope: token["scope"], **access_fields(user, true), exp: token["exp"],
                  token_name: token["token_name"])
      end

      # PUT /api/v1/catalogue: replaces the catalogue, answers as the auth app does (unknown is always empty here:
      # the fake has no role definitions).
      def catalogue_endpoint(body)
        return json(catalogue_status, error: "invalid_request", error_description: "refused by the test") if catalogue_status
        list = begin
          JSON.parse(body.to_s)["permissions"]
        rescue JSON::ParserError, NoMethodError, TypeError
          nil
        end
        unless list.is_a?(Array) && list.all? { _1.is_a?(Hash) && _1["key"].is_a?(String) && !_1["key"].empty? }
          return json(400, error: "invalid_request", error_description: "permissions must be a list of objects with a key")
        end
        before = (@catalogue || []).map { _1["key"] }
        keys = list.map { _1["key"] }
        @catalogue = list.map { _1.slice("key", "label", "group") }
        @catalogue_pushes += 1
        json(200, app: app, count: keys.size, added: (keys - before).sort, removed: (before - keys).sort, changed: [], unknown: [])
      end
    end
  end
end
