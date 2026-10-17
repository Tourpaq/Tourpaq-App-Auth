# Checks the three Entra values before anyone tries to sign in (SPECS.md §3, §19).
#
# A value pasted into Coolify with a quote or a space around it otherwise surfaces only at the first sign-in,
# as "bad URI (is not URI?)" for the tenant or "invalid_client" from Microsoft for the secret. Production refuses
# to boot instead (config/initializers/auth.rb), naming the variable and the problem but never the secret.
module EntraSettings
  GUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  # A tenant may also be named by a verified domain, e.g. tourpaq.onmicrosoft.com.
  DOMAIN = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\z/i
  WRAPPERS = /\A\s|\s\z|\A["'`]|["'`]\z/

  module_function

  # Problems with the values that are set; unset ones are someone else's check.
  def problems(tenant_id:, client_id:, client_secret:)
    found = []
    if tenant_id.present? && !(tenant_id.match?(GUID) || tenant_id.match?(DOMAIN))
      found << "ENTRA_TENANT_ID is not a tenant id (a GUID such as fd009888-…) or a tenant domain: got #{tenant_id.inspect}. " \
               "Remove any quotes or spaces around it."
    end
    if client_id.present? && !client_id.match?(GUID)
      found << "ENTRA_CLIENT_ID is not a GUID (the Application (client) ID): got #{client_id.inspect}. " \
               "Remove any quotes or spaces around it."
    end
    if client_secret.present? && client_secret.match?(WRAPPERS)
      found << "ENTRA_CLIENT_SECRET starts or ends with a quote or a space (#{client_secret.length} characters). " \
               "Paste the secret's Value exactly, with nothing around it."
    end
    found
  end
end
