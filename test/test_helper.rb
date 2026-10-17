ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Per-area helpers (test/support/*.rb). Fixtures stay small and shared; tests build the rest.
Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { require _1 }

# OmniAuth never talks to Entra in tests: POST /auth/entra_id redirects straight to the callback
# with OmniAuth.config.mock_auth[:entra_id] (EntraHelpers#mock_entra).
OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    # PARALLEL_WORKERS overrides the worker count (Rails reads it).
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include EntraHelpers
  end
end

class ActionDispatch::IntegrationTest
  include HostHelpers
  include SignInHelpers

  # Every integration test starts on the auth host (the issuer), not on Rails' default www.example.com.
  setup { on_auth_host! }

  teardown { OmniAuth.config.mock_auth[:entra_id] = nil }
end
