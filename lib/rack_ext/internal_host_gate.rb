# The back-channel hosts (AUTH_INTERNAL_HOSTS, SPECS.md §24.1), e.g. host.docker.internal:3050 or auth:3050,
# are in config.hosts so that apps on a shared Docker network can reach the auth app without the proxy. On
# them only the server-to-server endpoints answer: discovery, JWKS, /oauth/token, /oauth/introspect,
# /oauth/revoke, /oauth/userinfo and /api/v1/*. Every other path (sign-in, /oauth/authorize, the index, the
# admin UI …) is 404, before OmniAuth or the router see it. The health checks answer on any host.
#
# The issuer and every URL the app writes come from APP_URL, never from this Host header (Oidc::IdToken.issuer,
# the discovery document, redirects): a call through an internal host gets exactly the answer the auth host gives.
class InternalHostGate
  BACK_CHANNEL = %r{\A(/\.well-known/openid-configuration|/oauth/(jwks|token|introspect|revoke|userinfo)|/api/v1/.+|/up|/up/ready)\z}

  def initialize(app) = @app = app

  def call(env)
    request = ActionDispatch::Request.new(env)
    if AuthHosts.internal?(request) && !request.path.match?(BACK_CHANNEL)
      return [ 404, { "content-type" => "text/plain" }, [ "Not Found" ] ]
    end
    @app.call(env)
  end
end
