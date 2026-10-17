require "test_helper"

# The ID-token checks of the Entra strategy (SPECS.md §3.1, §22): signature against the JWKS,
# issuer, audience, expiry, nonce and tenant.
class EntraIdTokenTest < ActiveSupport::TestCase
  CLIENT_ID = "entra-client-id".freeze

  setup do
    @keys = EntraHelpers::FakeEntraKeys.new
    OmniAuth::EntraIdToken.jwks_fetcher = @keys
    OmniAuth::EntraIdToken.reset_cache!
    @tenant = entra_tenant_id
    @nonce = "nonce-123"
  end

  teardown do
    OmniAuth::EntraIdToken.jwks_fetcher = nil
    OmniAuth::EntraIdToken.reset_cache!
  end

  def claims(overrides = {})
    now = Time.now.to_i
    { iss: "https://login.microsoftonline.com/#{@tenant}/v2.0", aud: CLIENT_ID, iat: now, nbf: now, exp: now + 3600,
      nonce: @nonce, tid: @tenant, oid: "oid-1", email: "mwi@tourpaq.com", name: "Mogens", preferred_username: "mwi@tourpaq.com" }.merge(overrides)
  end

  def verify(token, nonce: @nonce) = OmniAuth::EntraIdToken.verify!(token, tenant_id: @tenant, client_id: CLIENT_ID, nonce: nonce)

  def assert_refused(pattern, token, **options)
    error = assert_raises(OmniAuth::EntraIdToken::Invalid) { verify(token, **options) }
    assert_match pattern, error.message
  end

  test "a valid token gives its claims" do
    result = verify(@keys.id_token(claims))
    assert_equal [ "oid-1", @tenant, "mwi@tourpaq.com" ], result.values_at("oid", "tid", "email")
  end

  test "wrong tenant: another tenant's issuer, or a tid that differs" do
    other = SecureRandom.uuid
    assert_refused(/issuer/, @keys.id_token(claims(iss: "https://login.microsoftonline.com/#{other}/v2.0", tid: other)))
    assert_refused(/tenant/, @keys.id_token(claims(tid: other)))
  end

  test "wrong audience" do
    assert_refused(/audience/, @keys.id_token(claims(aud: "another-app")))
  end

  test "bad or missing nonce" do
    assert_refused(/nonce/, @keys.id_token(claims(nonce: "other")))
    assert_refused(/nonce/, @keys.id_token(claims(nonce: nil)))
    assert_refused(/nonce/, @keys.id_token(claims), nonce: nil)
  end

  test "expired, beyond the leeway" do
    assert_refused(/expired/, @keys.id_token(claims(exp: Time.now.to_i - 120)))
    assert verify(@keys.id_token(claims(exp: Time.now.to_i - 30))), "within the 60 s leeway"
  end

  test "a signature by another key is refused" do
    forged = @keys.id_token(claims, key: OpenSSL::PKey::RSA.generate(2048))
    assert_refused(/rejected/, forged)
  end

  test "an unsigned or HS256 token is refused" do
    assert_refused(/rejected/, JWT.encode(claims.stringify_keys, nil, "none"))
    assert_refused(/rejected/, JWT.encode(claims.stringify_keys, "secret", "HS256"))
  end

  test "an unknown kid refetches the JWKS (Entra rotated its keys)" do
    verify(@keys.id_token(claims))
    assert_equal 1, @keys.fetches
    verify(@keys.id_token(claims))
    assert_equal 1, @keys.fetches, "cached"
    travel 6.minutes do
      @keys.instance_variable_set(:@kid, "entra-key-2")
      verify(@keys.id_token(claims(iat: Time.now.to_i, nbf: Time.now.to_i, exp: Time.now.to_i + 3600)))
    end
    assert_equal 2, @keys.fetches
  end

  test "a missing oid is refused" do
    assert_refused(/oid/, @keys.id_token(claims(oid: nil)))
  end
end
