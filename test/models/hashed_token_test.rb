require "test_helper"

class HashedTokenTest < ActiveSupport::TestCase
  test "generate: prefix plus 43 urlsafe characters; hint is the prefix plus 6" do
    plain = HashedToken.generate(prefix: "tpa_irm_")
    assert_match(/\Atpa_irm_[A-Za-z0-9_-]{43}\z/, plain)
    assert_equal plain.first(14), HashedToken.hint_for(plain, prefix: "tpa_irm_")
    assert_equal Digest::SHA256.hexdigest(plain), HashedToken.digest(plain)
  end

  test "assign_new_token sets digest and hint on the configured columns; token_matches? compares" do
    secret = ClientSecret.new(client: clients(:irm_web))
    plain = secret.assign_new_token(prefix: "tpcs_")
    assert_equal HashedToken.digest(plain), secret.secret_digest
    assert_equal plain.first(11), secret.hint
    assert secret.token_matches?(plain)
    assert_not secret.token_matches?(plain + "x")
    assert_not secret.token_matches?(nil)
    secret.save!
    assert_equal secret, ClientSecret.find_by_token(plain)
    assert_nil ClientSecret.find_by_token("")
  end
end
