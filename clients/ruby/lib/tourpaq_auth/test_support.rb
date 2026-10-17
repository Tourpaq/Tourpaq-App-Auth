require "tourpaq_auth"
require_relative "test_support/fake_provider"

module TourpaqAuth
  # Test helpers for apps (and the gem's own tests). In test/test_helper.rb:
  #
  #   require "tourpaq_auth/test_support"
  #   class ActiveSupport::TestCase
  #     include TourpaqAuth::TestSupport::Helpers
  #   end
  #
  #   with_tourpaq_auth(client_id: "irm-web") do |provider|
  #     sub = provider.add_user(email: "jjr@tourpaq.com", role: "responder")
  #     …
  #   end
  module TestSupport
    module Helpers
      # Configures TourpaqAuth against a fresh FakeProvider (or the one given) for the block, then puts the
      # previous configuration back. Keyword arguments go to FakeProvider.new; `env` overrides LOGIN_*.
      def with_tourpaq_auth(provider = nil, env: {}, **provider_options)
        provider ||= FakeProvider.new(**provider_options)
        previous = TourpaqAuth.instance_variable_get(:@config)
        provider.install!(env)
        yield provider
      ensure
        previous ? TourpaqAuth.config = previous : TourpaqAuth.instance_variable_set(:@config, nil)
        TourpaqAuth.reset!
      end
    end
  end
end
