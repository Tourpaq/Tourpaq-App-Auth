# Tunables of the auth app (SPECS.md §19, §24), read once from the environment into
# Rails.configuration.x.auth. Use AuthHosts for the three hosts and the internal back-channel hosts.
#
# Tests ignore the environment (a developer's .env must not change them): the hosts are
# auth.example.com (AUTH, the issuer), index.example.com (INDEX) and admin.example.com (ADMIN), and the
# back-channel host auth-internal.example.com:3050 stands in for AUTH_INTERNAL_HOSTS.
require "ipaddr"
require_relative "../../lib/entra_settings"

Rails.application.config.x.auth = ActiveSupport::OrderedOptions.new.tap do |auth|
  env = Rails.env.test? ? {} : ENV
  building_assets = ENV["SECRET_KEY_BASE_DUMMY"].present?
  required = lambda do |name, dev_default|
    value = env[name].presence
    next value.chomp("/") if value
    raise "Set #{name} (see .env.example)" if Rails.env.production? && !building_assets
    dev_default
  end
  list = ->(value) { value.to_s.split(/[\s,;]+/).map(&:strip).reject(&:blank?) }

  # --- Hosts (SPECS.md §24.1, §19) ---
  # AUTH: Entra sign-in, the OIDC provider, the API. APP_URL is the issuer, exactly (https://auth.app.journeybooking.eu).
  auth.app_url = required.("APP_URL", Rails.env.test? ? "http://auth.example.com" : "http://auth.localhost:3050")
  # INDEX: the index, profile and tokens (https://index.app.journeybooking.eu).
  auth.index_url = required.("INDEX_URL", Rails.env.test? ? "http://index.example.com" : "http://index.localhost:3050")
  # ADMIN: the admin UI (https://admin.app.journeybooking.eu).
  auth.admin_url = required.("ADMIN_URL", Rails.env.test? ? "http://admin.example.com" : "http://admin.localhost:3050")
  # Optional back-channel hosts ("host" or "host:port", comma-separated), e.g. host.docker.internal:3050,auth:3050:
  # apps on a shared Docker network (or in local testing) call discovery, JWKS, /oauth/token, introspect, revoke,
  # userinfo and /api/v1/* there. Nothing else answers on them, and the issuer stays APP_URL (§24.1).
  auth.internal_hosts = Rails.env.test? ? [ "auth-internal.example.com:3050" ] : list.(env["AUTH_INTERNAL_HOSTS"]).map(&:downcase)
  # Optional: admin requests from other addresses are refused (e.g. the NetBird range 100.64.0.0/10).
  auth.admin_allowed_cidrs = list.(env["ADMIN_ALLOWED_CIDRS"]).map { IPAddr.new(_1) }
  # Optional: the proxies allowed to set X-Forwarded-For (Coolify's Traefik). Default: Rails' private ranges.
  auth.trusted_proxies = list.(env["TRUSTED_PROXIES"]).map { IPAddr.new(_1) }

  # --- Sessions (SPECS.md §3.3, §11.2) ---
  auth.session_idle = env.fetch("SESSION_IDLE_HOURS", "8").to_f.hours
  auth.session_max = env.fetch("SESSION_MAX_DAYS", "7").to_f.days
  auth.admin_session_idle = env.fetch("ADMIN_SESSION_IDLE_HOURS", "2").to_f.hours
  auth.admin_reauth = env.fetch("ADMIN_REAUTH_HOURS", "12").to_f.hours

  # --- Entra ID (SPECS.md §3). Never in the repository: Coolify's environment only. ---
  # Development and tests use the fake identity provider's tenant unless one is set.
  auth.entra_tenant_id = env["ENTRA_TENANT_ID"].presence || (Rails.env.production? ? nil : "00000000-0000-4000-8000-00000000fa4e")
  auth.entra_client_id = env["ENTRA_CLIENT_ID"].presence
  auth.entra_client_secret = env["ENTRA_CLIENT_SECRET"].presence
  auth.entra_client_secret_expires_on = (Date.iso8601(env["ENTRA_CLIENT_SECRET_EXPIRES_ON"]) rescue nil)
  # The redirect_uri sent to Entra, in the authorization request and the code exchange (SPECS.md §24.2). Default:
  # the auth host's own callback. While the registration only has home.app's callback, set it to
  # https://home.app.journeybooking.eu/auth/entra_id/callback: the Dashboard forwards that GET here.
  auth.entra_redirect_uri = env["ENTRA_REDIRECT_URI"].presence || "#{auth.app_url}/auth/entra_id/callback"
  # Entra puts auth_time (when the person last gave Microsoft their credentials) in its ID token only when the
  # registration has it as an optional claim. Without it, freshness (the admin host's 12 hours, an app's
  # prompt=login / max_age) counts from the last Entra sign-in the auth app completed. true: require auth_time,
  # so a fresh sign-in is proven, not just requested (set it once IT has added the optional claim). SPECS.md §3.1.
  auth.entra_require_auth_time = env["ENTRA_REQUIRE_AUTH_TIME"].to_s == "true"
  # A quote or space pasted around a value would otherwise only show at the first sign-in (lib/entra_settings.rb).
  entra_problems = EntraSettings.problems(tenant_id: env["ENTRA_TENANT_ID"], client_id: env["ENTRA_CLIENT_ID"],
                                          client_secret: env["ENTRA_CLIENT_SECRET"])
  if entra_problems.any?
    raise entra_problems.join("\n") if Rails.env.production? && !building_assets
    entra_problems.each { warn "[auth] #{_1}" }
  end

  # --- OIDC provider signing keys (SPECS.md §7.3, §14): PEM, "\n" escapes allowed ---
  auth.oidc_signing_key = env["OIDC_SIGNING_KEY"].presence&.gsub("\\n", "\n")
  auth.oidc_previous_signing_key = env["OIDC_PREVIOUS_SIGNING_KEY"].presence&.gsub("\\n", "\n")

  # --- Optional integrations ---
  auth.teams_webhook_url = env["TEAMS_WEBHOOK_URL"].presence
  auth.irm_heartbeat_url = env["IRM_HEARTBEAT_URL"].presence
end

Rails.application.configure do
  auth = config.x.auth
  # Exactly the three hosts plus the back-channel hosts (SPECS.md §19, §24.1). InternalHostGate (lib/rack_ext)
  # answers only the back-channel endpoints on the latter. The health checks are excluded: Coolify calls
  # http://127.0.0.1:3050/up from inside the container.
  config.hosts = ([ URI(auth.app_url).host, URI(auth.index_url).host, URI(auth.admin_url).host ] + auth.internal_hosts).uniq
  config.host_authorization = { exclude: ->(request) { request.path == "/up" || request.path == "/up/ready" } }
  config.action_dispatch.trusted_proxies = auth.trusted_proxies if auth.trusted_proxies.any?
end
