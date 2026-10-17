# The fake identity provider (SPECS.md §3.4): stands in for Entra in development and tests only.
# It builds the same OmniAuth auth hash as the real strategy (lib/omniauth/strategies/
# tourpaq_entra_id.rb): provider "entra_id", uid tid+oid, the ID token's claims in extra.raw_info.
#
# The oid is derived from the email, so signing in again as the same address is the same Entra
# account, and a pre-created user is bound at the first fake sign-in just like with Entra.
module FakeIdentity
  module_function

  def enabled? = Rails.env.development? || Rails.env.test?

  def tenant_id = Rails.configuration.x.auth.entra_tenant_id

  # A stable UUID-shaped oid for an email address.
  def oid_for(email)
    hex = Digest::SHA256.hexdigest("fake-entra-oid:#{email.to_s.strip.downcase}")
    "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
  end

  # Claims may be overridden or removed (nil) to test refusals: auth_hash(email: …, tid: "other").
  # The fake provider always "asks for credentials", so auth_time is now (Entra sends it as the optional
  # claim auth_time, SPECS.md §3.1).
  def auth_hash(email:, name: nil, oid: nil, tid: tenant_id, upn: email, **extra_claims)
    oid ||= oid_for(email)
    claims = {
      "oid" => oid, "tid" => tid, "email" => email, "name" => name.presence || email.to_s.split("@").first,
      "preferred_username" => upn, "iss" => "https://login.microsoftonline.com/#{tid}/v2.0",
      "aud" => Rails.configuration.x.auth.entra_client_id || "fake-client-id", "auth_time" => Time.current.to_i
    }.merge(extra_claims.transform_keys(&:to_s)).compact

    OmniAuth::AuthHash.new(
      provider: "entra_id",
      uid: "#{tid}#{oid}",
      info: { name: claims["name"], email: claims["email"].presence || claims["preferred_username"], nickname: claims["preferred_username"] },
      extra: { raw_info: claims }
    )
  end
end
