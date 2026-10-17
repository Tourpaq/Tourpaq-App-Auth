# The hosts of the one app (SPECS.md §24.1), all from Rails.configuration.x.auth:
#
#   AUTH   (APP_URL, the issuer)  Entra sign-in, OIDC provider, authorization API, introspection, catalogue,
#                                 the "waiting for access" and "no access" pages, sign out
#   INDEX  (INDEX_URL)            the index, profile and tokens; signs in through AUTH as internal client "index"
#   ADMIN  (ADMIN_URL)            the admin UI; signs in through AUTH as internal client "admin"
#   internal (AUTH_INTERNAL_HOSTS) back-channel only: discovery, JWKS, /oauth/token, introspect, revoke,
#                                 userinfo and /api/v1/* for apps on a shared Docker network (InternalHostGate)
#
# The issuer, the iss claim, discovery's URLs and every redirect come from APP_URL, never from the Host header.
module AuthHosts
  module_function

  def config = Rails.configuration.x.auth

  def auth_url = config.app_url
  def index_url = config.index_url
  def admin_url = config.admin_url
  def auth_host = URI(auth_url).host
  def index_host = URI(index_url).host
  def admin_host = URI(admin_url).host
  def public_hosts = [ auth_host, index_host, admin_host ]

  # The internal clients' OIDC redirect URIs (SPECS.md §11.2, §24.1).
  def admin_callback_url = "#{admin_url}/sso/callback"
  def index_callback_url = "#{index_url}/sso/callback"

  # The auth host's pages the other hosts link to.
  def waiting_url = "#{auth_url}/waiting"

  def auth?(request) = host_of(request) == auth_host
  def index?(request) = host_of(request) == index_host
  def admin?(request) = host_of(request) == admin_host

  # A back-channel host from AUTH_INTERNAL_HOSTS: "host" matches any port, "host:port" only that port.
  # Never one of the three public hosts.
  def internal?(request)
    host = host_of(request)
    return false if public_hosts.include?(host)
    with_port = "#{host}:#{request.port}"
    config.internal_hosts.any? { |entry| entry.include?(":") ? entry == with_port : entry == host }
  end

  def host_of(request) = request.host.to_s.downcase

  # Route constraints: `constraints(AuthHosts::Auth) { … }`.
  module Auth
    def self.matches?(request) = AuthHosts.auth?(request)
  end

  module Index
    def self.matches?(request) = AuthHosts.index?(request)
  end

  module Admin
    def self.matches?(request) = AuthHosts.admin?(request)
  end

  # The server-to-server endpoints: on the auth host and on the internal hosts.
  module BackChannel
    def self.matches?(request) = AuthHosts.auth?(request) || AuthHosts.internal?(request)
  end
end
