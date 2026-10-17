require "test_helper"

class ConfigurationTest < TourpaqAuthTestCase
  FULL = { "LOGIN_ISSUER" => "https://home.example.test/", "LOGIN_CLIENT_ID" => "irm-web", "LOGIN_CLIENT_SECRET" => "s3cret" }.freeze

  def test_disabled_unless_issuer_client_id_and_secret_are_all_set
    FULL.each_key do |missing|
      refute TourpaqAuth::Configuration.new(FULL.merge(missing => " ")).enabled?, "#{missing} blank"
    end
    assert TourpaqAuth::Configuration.new(FULL).enabled?
  end

  def test_defaults
    config = TourpaqAuth::Configuration.new(FULL)
    assert_equal "https://home.example.test", config.issuer, "trailing slash dropped"
    assert_equal "openid email profile", config.scopes
    assert_equal 300, config.access_cache_seconds
    assert_equal 24 * 3600, config.grace_seconds
    assert_equal 60, config.introspection_cache_seconds
    assert_nil config.redirect_uri
  end

  def test_values_from_the_environment
    config = TourpaqAuth::Configuration.new(FULL.merge("LOGIN_SCOPES" => "openid email", "LOGIN_ACCESS_CACHE_SECONDS" => "120",
                                                       "LOGIN_GRACE_HOURS" => "72", "LOGIN_REDIRECT_URI" => "https://irm.example.test/sso/callback"))
    assert_equal "openid email", config.scopes
    assert_equal 120, config.access_cache_seconds
    assert_equal 72 * 3600, config.grace_seconds
    assert_equal "https://irm.example.test/sso/callback", config.redirect_uri
  end

  def test_role_claim_is_derived_from_the_client_id_unless_set
    assert_equal "irm_role", TourpaqAuth::Configuration.new(FULL).role_claim
    assert_equal "azure_cost_role", TourpaqAuth::Configuration.new(FULL.merge("LOGIN_CLIENT_ID" => "azure-cost-web")).role_claim
    assert_equal "role", TourpaqAuth::Configuration.new(FULL.merge("LOGIN_ROLE_CLAIM" => "role")).role_claim
  end

  def test_configure_reads_env_then_applies_the_block
    with_env(FULL.to_h) do
      previous = TourpaqAuth.instance_variable_get(:@config)
      begin
        TourpaqAuth.configure { |config| config.grace_hours = 48 }
        assert TourpaqAuth.enabled?
        assert_equal "irm-web", TourpaqAuth.config.client_id
        assert_equal 48 * 3600, TourpaqAuth.config.grace_seconds
      ensure
        TourpaqAuth.instance_variable_set(:@config, previous)
      end
    end
  end

  def test_without_rails_the_cache_is_a_memory_store
    assert_kind_of TourpaqAuth::MemoryStore, TourpaqAuth::Configuration.new(FULL).cache
  end

  def test_memory_store_expires_entries
    with_auth do
      store = TourpaqAuth::MemoryStore.new
      store.write("a", 1, expires_in: 10)
      store.write("b", 2)
      assert_equal 1, store.read("a")
      travel 11
      assert_nil store.read("a")
      assert_equal 2, store.read("b")
      assert store.delete("b")
      assert_nil store.read("b")
    end
  end
end
