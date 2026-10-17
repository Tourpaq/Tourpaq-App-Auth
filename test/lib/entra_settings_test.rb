require "test_helper"
require "entra_settings"

class EntraSettingsTest < ActiveSupport::TestCase
  GUID = "fd009888-e016-48f0-9889-7a80325b7ff6".freeze

  def problems(tenant_id: GUID, client_id: GUID, client_secret: "abc~DEF.123")
    EntraSettings.problems(tenant_id:, client_id:, client_secret:)
  end

  test "good values, or unset ones, have no problems" do
    assert_empty problems
    assert_empty problems(tenant_id: "tourpaq.onmicrosoft.com")
    assert_empty problems(tenant_id: nil, client_id: nil, client_secret: nil)
  end

  test "a quote pasted after the tenant id is caught, as seen in production" do
    found = problems(tenant_id: "#{GUID}\"")
    assert_equal 1, found.size
    assert_match "ENTRA_TENANT_ID", found.first
  end

  test "quotes or spaces around the tenant or client id are caught" do
    [ "\"#{GUID}\"", " #{GUID}", "#{GUID} ", "'#{GUID}'" ].each do |bad|
      assert_match "ENTRA_TENANT_ID", problems(tenant_id: bad).join, bad.inspect
      assert_match "ENTRA_CLIENT_ID", problems(client_id: bad).join, bad.inspect
    end
  end

  test "a secret wrapped in quotes or spaces is caught without printing the secret" do
    [ "\"s3cret~value\"", "s3cret~value ", " s3cret~value", "'s3cret~value'" ].each do |bad|
      found = problems(client_secret: bad).join
      assert_match "ENTRA_CLIENT_SECRET", found
      assert_no_match "s3cret", found
    end
  end
end
