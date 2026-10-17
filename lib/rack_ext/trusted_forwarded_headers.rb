require "ipaddr"

# Only the proxy (Coolify's Traefik) may set X-Forwarded-* (SPECS.md §11.2). Rails' remote_ip takes
# X-Forwarded-For entries even when the direct peer is not a proxy, so a client reaching the app
# directly could claim any address (ADMIN_ALLOWED_CIDRS, rate limits, audit IPs) or host. This
# drops the forwarded headers unless REMOTE_ADDR is a trusted proxy: TRUSTED_PROXIES when set,
# otherwise Rails' defaults (loopback and private ranges, where the Docker network lives).
class TrustedForwardedHeaders
  HEADERS = %w[HTTP_X_FORWARDED_FOR HTTP_X_FORWARDED_HOST HTTP_X_FORWARDED_PROTO HTTP_X_FORWARDED_PORT
               HTTP_X_FORWARDED_SSL HTTP_CLIENT_IP HTTP_FORWARDED].freeze

  def initialize(app) = @app = app

  def call(env)
    HEADERS.each { env.delete(_1) } unless trusted?(env["REMOTE_ADDR"])
    @app.call(env)
  end

  private

  def trusted?(address)
    ip = IPAddr.new(address.to_s)
    proxies = Rails.application.config.action_dispatch.trusted_proxies || ActionDispatch::RemoteIp::TRUSTED_PROXIES
    proxies.any? { |proxy| proxy.is_a?(IPAddr) ? proxy.include?(ip) : proxy === address }
  rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
    false
  end
end
