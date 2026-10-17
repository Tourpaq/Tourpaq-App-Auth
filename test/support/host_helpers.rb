# The hosts in tests (config/initializers/auth.rb, SPECS.md §24.1): auth = auth.example.com (the issuer, and
# where every integration test starts), index = index.example.com, admin = admin.example.com, and the
# back-channel host auth-internal.example.com:3050 (AUTH_INTERNAL_HOSTS).
module HostHelpers
  def auth_host = AuthHosts.auth_host
  def index_host = AuthHosts.index_host
  def admin_host = AuthHosts.admin_host
  def internal_host = Rails.configuration.x.auth.internal_hosts.first

  def on_auth_host! = host!(auth_host)
  def on_index_host! = host!(index_host)
  def on_admin_host! = host!(admin_host)
  def on_internal_host! = host!(internal_host)

  # A signed cookie value as this app would set it (for sending a forged or moved cookie by hand:
  # get path, headers: { "Cookie" => cookie_header(name => value) }).
  def signed_cookie(name, value)
    jar = ActionDispatch::TestRequest.create(Rails.application.env_config).cookie_jar
    jar.signed[name] = value
    jar[name]
  end

  def cookie_header(pairs) = pairs.map { |name, value| "#{name}=#{Rack::Utils.escape(value)}" }.join("; ")
end
