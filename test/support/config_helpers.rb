# Temporarily changes Rails.configuration.x.auth values:
#   with_auth_config(admin_allowed_cidrs: [IPAddr.new("100.64.0.0/10")]) { … }
module ConfigHelpers
  def with_auth_config(values)
    config = Rails.configuration.x.auth
    previous = values.keys.to_h { [ _1, config[_1] ] }
    values.each { |key, value| config[key] = value }
    yield
  ensure
    previous.each { |key, value| config[key] = value }
  end
end

ActiveSupport::TestCase.include(ConfigHelpers)

module ValueAssertions
  # assert_equal that also accepts nil as the expected value (Minitest wants assert_nil for that).
  def assert_same_value(expected, actual, message = nil)
    expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
  end
end

ActiveSupport::TestCase.include(ValueAssertions)
