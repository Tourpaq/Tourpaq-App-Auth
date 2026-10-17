require "test_helper"

class ClientTest < ActiveSupport::TestCase
  setup { @client = clients(:irm_web) }

  test "generate_secret! returns the plain secret once and stores only its digest" do
    plain = @client.generate_secret!(created_by: users(:mwi))
    assert_match(/\Atpcs_[A-Za-z0-9_-]{43}\z/, plain)
    secret = @client.client_secrets.last
    assert_equal HashedToken.digest(plain), secret.secret_digest
    assert_equal plain.first(11), secret.hint
    assert_not ClientSecret.where(secret_digest: plain).exists?
    assert_equal "client.secret_created", AuditEvent.last.action
    assert_equal apps(:irm), AuditEvent.last.app
  end

  test "at most two active secrets; an expired one does not count" do
    @client.generate_secret!
    @client.generate_secret!
    assert_raises(Client::TooManySecrets) { @client.generate_secret! }
    @client.client_secrets.first.update!(expires_at: 1.minute.ago)
    assert @client.generate_secret!
  end

  test "authenticate_secret accepts either active secret and nothing else" do
    old = @client.generate_secret!
    new = @client.generate_secret!(expires_at: 1.year.from_now)
    assert_equal @client.client_secrets.find_by(secret_digest: HashedToken.digest(old)), @client.authenticate_secret(old)
    assert @client.authenticate_secret(new)
    assert_nil @client.authenticate_secret("tpcs_wrong")
    assert_nil @client.authenticate_secret(nil)
    assert_nil clients(:kpi_web).authenticate_secret(old), "another client's secret"

    @client.client_secrets.find_by(secret_digest: HashedToken.digest(old)).update!(expires_at: 1.second.ago)
    assert_nil @client.authenticate_secret(old), "expired"
    assert_not_nil @client.client_secrets.find_by(secret_digest: HashedToken.digest(new)).reload.last_used_at
  end

  test "Client.authenticate by client_id and secret; disabled clients and apps are refused" do
    plain = @client.generate_secret!
    assert_equal @client, Client.authenticate("irm-web", plain)
    assert_nil Client.authenticate("kpi-web", plain)
    apps(:irm).update!(disabled_at: Time.current)
    assert_nil Client.authenticate("irm-web", plain)
    apps(:irm).update!(disabled_at: nil)
    @client.update!(disabled_at: Time.current)
    assert_nil Client.authenticate("irm-web", plain)
  end

  test "extension and internal clients have no secrets" do
    assert_raises(ArgumentError) { clients(:irm_extension).generate_secret! }
    assert_nil clients(:irm_extension).authenticate_secret("anything")
    assert clients(:irm_extension).requires_pkce?
    assert_not clients(:irm_extension).may_call_api?
  end

  test "redirect URIs match exactly" do
    assert @client.redirect_uri_allowed?("https://irm.app.journeybooking.eu/sso/callback")
    assert @client.redirect_uri_allowed?("http://localhost:3030/sso/callback")
    assert_not @client.redirect_uri_allowed?("https://irm.app.journeybooking.eu/sso/callback/")
    assert_not @client.redirect_uri_allowed?("https://irm.app.journeybooking.eu/sso/callback?x=1")
    assert_not @client.redirect_uri_allowed?("HTTPS://irm.app.journeybooking.eu/sso/callback")
    assert_not @client.redirect_uri_allowed?(nil)
    assert @client.post_logout_redirect_uri_allowed?("https://irm.app.journeybooking.eu/")
    assert_not @client.post_logout_redirect_uri_allowed?("https://evil.example/")
  end

  test "redirect URIs must be https (http only for localhost), without wildcards or fragments" do
    client = Client.new(app: apps(:kpi), client_id: "kpi-test", kind: "web")
    client.redirect_uris = "https://kpi.app.journeybooking.eu/sso/callback\nhttp://127.0.0.1:3040/cb, http://localhost:3040/cb"
    assert client.valid?, client.errors.full_messages.to_sentence
    assert_equal 3, client.redirect_uris.size
    %w[http://kpi.app.journeybooking.eu/cb https://*.journeybooking.eu/cb https://kpi.app.journeybooking.eu/cb#x
       https://user:pw@kpi.app.journeybooking.eu/cb not-a-uri].each do |bad|
      client.redirect_uris = [ bad ]
      assert_not client.valid?, bad
    end
  end

  test "client ids are lowercase slugs; web and extension clients need an app" do
    assert_not Client.new(app: apps(:kpi), client_id: "Bad Id", kind: "web").valid?
    assert_not Client.new(client_id: "orphan", kind: "web").valid?
    assert_not Client.new(app: apps(:kpi), client_id: "kpi-x", kind: "other").valid?
  end

  test "the admin client is internal, has no app, and its redirect URI comes from ADMIN_URL" do
    admin = Client.admin_client
    assert_equal clients(:admin), admin
    assert admin.internal?
    assert admin.active?
    assert_equal [ "http://admin.example.com/sso/callback" ], admin.redirect_uris
    assert admin.redirect_uri_allowed?("http://admin.example.com/sso/callback")
  end
end
