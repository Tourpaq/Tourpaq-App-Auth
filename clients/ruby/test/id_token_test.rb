require "test_helper"

class IdTokenTest < TourpaqAuthTestCase
  def verify(token, nonce: "n1") = TourpaqAuth::IdToken.verify(token, nonce: nonce)

  def test_a_valid_token_returns_a_login
    with_auth(client_id: "kpi-web") do |provider|
      provider.nonce = "n1"
      login = verify(provider.id_token(sub: "s-1", kpi_role: "editor", sessions_valid_after: 1_791_900_000, auth_time: 1_791_000_000))
      assert_equal "s-1", login.sub
      assert_equal "editor", login.role
      assert_equal "someone@example.test", login.email
      assert_equal Time.at(1_791_900_000).utc, login.sessions_valid_after
      assert_equal Time.at(1_791_000_000).utc, login.authenticated_at
    end
  end

  def test_the_role_claim_name_is_configurable
    with_auth(env: { "LOGIN_ROLE_CLAIM" => "app_role" }) do |provider|
      provider.nonce = "n1"
      assert_equal "admin", verify(provider.id_token(app_role: "admin", test_role: "viewer")).role
      assert_nil verify(provider.id_token(test_role: "viewer")).role
    end
  end

  def test_email_falls_back_to_preferred_username
    with_auth do |provider|
      provider.nonce = "n1"
      assert_equal "upn@example.test", verify(provider.id_token(email: nil, preferred_username: "UPN@example.test")).email
    end
  end

  def test_wrong_nonce_audience_issuer_expiry_and_issued_at_are_refused
    with_auth do |provider|
      provider.nonce = "n1"
      now = Time.now.to_i
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token, nonce: "other") }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token, nonce: nil) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(nonce: nil)) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(aud: "someone-else")) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(iss: "https://evil.example.test")) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(exp: now - 600)) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(iat: now + 3600)) }
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token(sub: nil)) }
    end
  end

  def test_a_token_signed_with_another_key_is_refused
    with_auth do |provider|
      provider.nonce = "n1"
      provider.forge_with_other_key!
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token) }
    end
  end

  def test_an_unsigned_token_is_refused
    with_auth do |provider|
      unsigned = JWT.encode({ iss: provider.issuer, aud: provider.client_id, sub: "x", exp: Time.now.to_i + 300, nonce: "n1" }, nil, "none")
      assert_raises(TourpaqAuth::LoginError) { verify(unsigned) }
    end
  end

  def test_an_unknown_key_id_fetches_the_keys_again_once
    with_auth do |provider|
      provider.nonce = "n1"
      verify(provider.id_token)
      assert_equal 1, provider.jwks_fetches
      verify(provider.id_token)
      assert_equal 1, provider.jwks_fetches, "cached"

      provider.rotate_key!
      assert verify(provider.id_token)
      assert_equal 2, provider.jwks_fetches

      provider.rotate_key!(keep_old: false)
      provider.instance_variable_set(:@kid, "unpublished")
      assert_raises(TourpaqAuth::LoginError) { verify(provider.id_token) }
      assert_equal 3, provider.jwks_fetches, "one refetch per unknown key id, not a loop"
    end
  end

  def test_jwks_are_cached_for_an_hour
    with_auth do |provider|
      TourpaqAuth::Client.jwks
      TourpaqAuth::Client.jwks
      assert_equal 1, provider.jwks_fetches
      travel 3601
      TourpaqAuth::Client.jwks
      assert_equal 2, provider.jwks_fetches
    end
  end
end
