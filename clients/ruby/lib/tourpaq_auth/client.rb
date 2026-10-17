module TourpaqAuth
  # The OIDC client side (authorization code + PKCE S256, state, nonce) of the auth app: discovery, the
  # authorization URL, the code exchange (client_secret_basic) and the signing keys. Generalised from the
  # IRM's Sso::Client. Discovery and JWKS are cached in-process for an hour; "is the auth app
  # reachable?" for five minutes.
  #
  # The short way through a login is begin_login / complete_login:
  #
  #   url, login = TourpaqAuth::Client.begin_login(redirect_uri: sso_callback_url)
  #   session[:tourpaq_login] = login          # small hash of strings: state, nonce, PKCE verifier
  #   redirect_to url, allow_other_host: true
  #
  #   # callback
  #   login = TourpaqAuth::Client.complete_login(session.delete(:tourpaq_login), params.to_unsafe_h)
  #   login.sub, login.email, login.role, …   # a TourpaqAuth::Login
  module Client
    CACHE_TTL = 3600
    REACHABLE_TTL = 300
    LOGIN_TTL = 600
    # Discovery's server-to-server URLs, which LOGIN_INTERNAL_URL moves (SPECS.md §24.1).
    BACKCHANNEL_KEYS = %w[token_endpoint jwks_uri userinfo_endpoint introspection_endpoint revocation_endpoint].freeze

    @cache = {}
    @mutex = Mutex.new

    class << self
      def reset!
        @mutex.synchronize { @cache = {} }
      end

      # The discovery document. With LOGIN_INTERNAL_URL it is fetched there, and its server-to-server URLs
      # (BACKCHANNEL_KEYS) are moved to that origin; the authorization and end-session URLs (the browser's) and
      # the issuer stay as the auth app wrote them, under LOGIN_ISSUER.
      def discovery
        cached("discovery", CACHE_TTL) do
          doc = get_json(config.backchannel_endpoint("/.well-known/openid-configuration"))
          unless doc.is_a?(Hash) && doc["issuer"].to_s.chomp("/") == config.issuer
            raise Error, "Discovery issuer #{doc.is_a?(Hash) ? doc['issuer'].inspect : 'missing'} does not match LOGIN_ISSUER"
          end
          BACKCHANNEL_KEYS.each { |key| doc[key] = config.backchannel_url(doc[key]) if doc[key] }
          doc
        end
      end

      # The provider's signing keys (a JWKS hash); refresh: true fetches them again (a key we do not know yet).
      def jwks(refresh: false)
        @mutex.synchronize { @cache.delete("jwks") } if refresh
        cached("jwks", CACHE_TTL) { get_json(discovery.fetch("jwks_uri")) }
      end

      # Does the auth app answer right now? Short timeout, cached, never raises.
      def reachable?
        cached("reachable", REACHABLE_TTL) do
          status, = config.http.call(:get, config.backchannel_endpoint("/.well-known/openid-configuration"), timeout: 3)
          status.to_i == 200
        rescue StandardError
          false
        end
      end

      # The URL to send the browser to. Extra parameters (max_age, prompt, login_hint) are passed on.
      def authorization_url(state:, nonce:, code_verifier:, redirect_uri: nil, **extra)
        query = { response_type: "code", client_id: config.client_id, redirect_uri: redirect_uri!(redirect_uri),
                  scope: config.scopes, state: state, nonce: nonce, code_challenge: pkce_challenge(code_verifier),
                  code_challenge_method: "S256" }.merge(extra).reject { |_, value| value.nil? }
        "#{discovery.fetch('authorization_endpoint')}?#{URI.encode_www_form(query)}"
      end

      # Exchanges the authorization code for tokens; returns the token response (with id_token).
      def exchange_code(code, code_verifier:, redirect_uri: nil)
        require_configured!
        status, body = config.http.call(:post, discovery.fetch("token_endpoint"),
          form: { grant_type: "authorization_code", code: code, redirect_uri: redirect_uri!(redirect_uri), code_verifier: code_verifier },
          headers: { "Authorization" => Http.basic_auth(config.client_id, config.client_secret) }, timeout: 10)
        json = Http.parse_json(body)
        json = {} unless json.is_a?(Hash)
        unless status.to_i == 200
          raise Unavailable, "The auth app answered #{status}" if status.to_i >= 500
          raise LoginError, "The token endpoint answered #{status}: #{json['error_description'] || json['error'] || 'no details'}"
        end
        raise LoginError, "The token response has no id_token" if json["id_token"].to_s.empty?
        json
      rescue *Http::NETWORK_ERRORS => e
        raise Unavailable, "The auth app cannot be reached (#{e.class})"
      end

      # Starts a login: returns [authorization URL, login hash]. Keep the hash (strings only, so it fits in
      # a cookie session) until the callback, and hand it to complete_login.
      def begin_login(redirect_uri: nil, **extra)
        login = { "state" => SecureRandom.urlsafe_base64(32), "nonce" => SecureRandom.urlsafe_base64(32),
                  "verifier" => SecureRandom.urlsafe_base64(48), "redirect_uri" => redirect_uri!(redirect_uri),
                  "at" => TourpaqAuth.now.to_i }
        url = authorization_url(state: login["state"], nonce: login["nonce"], code_verifier: login["verifier"],
                                redirect_uri: login["redirect_uri"], **extra)
        [ url, login ]
      end

      # Finishes a login from the callback's parameters ("code", "state", or "error"). Checks the state
      # and the login's age, exchanges the code and verifies the ID token. Returns a TourpaqAuth::Login;
      # raises LoginError (show it to the person) or Unavailable.
      def complete_login(login, params)
        login = (login || {}).transform_keys(&:to_s)
        params = params.to_h.transform_keys(&:to_s)
        if params["error"].to_s != ""
          raise LoginError, "The auth app did not sign you in: #{params['error_description'].to_s.empty? ? params['error'] : params['error_description']}."
        end
        unless login["state"] && TourpaqAuth.secure_compare(login["state"], params["state"].to_s)
          raise LoginError, "This sign-in was not started in this browser. Try again."
        end
        if login["at"].to_i <= TourpaqAuth.now.to_i - LOGIN_TTL
          raise LoginError, "This sign-in took longer than #{LOGIN_TTL / 60} minutes. Try again."
        end

        tokens = exchange_code(params["code"].to_s, code_verifier: login["verifier"], redirect_uri: login["redirect_uri"])
        IdToken.verify(tokens["id_token"], nonce: login["nonce"])
      end

      def end_session_endpoint = discovery["end_session_endpoint"]

      # Where to send the browser to end the auth session too (optional, SPECS.md §7.5).
      def end_session_url(post_logout_redirect_uri: nil, id_token_hint: nil, state: nil)
        endpoint = end_session_endpoint or return nil
        query = { client_id: config.client_id, post_logout_redirect_uri: post_logout_redirect_uri,
                  id_token_hint: id_token_hint, state: state }.reject { |_, value| value.nil? }
        "#{endpoint}?#{URI.encode_www_form(query)}"
      end

      def pkce_challenge(verifier)
        [ Digest::SHA256.digest(verifier.to_s) ].pack("m0").tr("+/", "-_").delete("=")
      end

      private

      def config = TourpaqAuth.config

      def require_configured!
        raise NotConfigured, "Tourpaq Auth is not configured (LOGIN_ISSUER, LOGIN_CLIENT_ID, LOGIN_CLIENT_SECRET)" unless config.enabled?
      end

      def redirect_uri!(value)
        value || config.redirect_uri || raise(Error, "No redirect URI: pass redirect_uri: or set LOGIN_REDIRECT_URI")
      end

      def cached(key, ttl)
        entry = @mutex.synchronize { @cache[key] }
        return entry[:value] if entry && entry[:at] > TourpaqAuth.now - ttl
        value = yield
        @mutex.synchronize { @cache[key] = { value: value, at: TourpaqAuth.now } }
        value
      end

      def get_json(url)
        require_configured!
        status, body = config.http.call(:get, url, timeout: config.http_timeout)
        raise Unavailable, "#{url} answered #{status}" if status.to_i >= 500 || status.to_i == 429
        raise Error, "#{url} answered #{status}" unless status.to_i == 200
        Http.parse_json(body)
      rescue *Http::NETWORK_ERRORS => e
        raise Unavailable, "The auth app cannot be reached (#{e.class})"
      end
    end
  end
end
