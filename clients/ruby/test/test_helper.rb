require "minitest/autorun"
require "tourpaq_auth"
require "tourpaq_auth/test_support"

# Wraps a MemoryStore and remembers every key and value written, to prove what is (not) cached.
class RecordingCache < TourpaqAuth::MemoryStore
  attr_reader :writes

  def initialize
    super
    @writes = []
  end

  def write(key, value, expires_in: nil)
    @writes << { key: key, value: value, expires_in: expires_in }
    super
  end
end

class TourpaqAuthTestCase < Minitest::Test
  include TourpaqAuth::TestSupport::Helpers

  def setup
    @offset = 0
  end

  # Runs the block against a fresh fake provider, with a clock the test can move (travel).
  def with_auth(provider = nil, env: {}, **options)
    with_tourpaq_auth(provider, env: env, **options) do |fake|
      TourpaqAuth.config.clock = -> { Time.now + @offset }
      yield fake
    end
  end

  # Moves the gem's clock forward. (JWT checks exp/iat against the real clock, so logins are tested
  # without travelling.)
  def travel(seconds)
    @offset += seconds
  end

  def with_env(values)
    previous = values.keys.to_h { [ _1, ENV[_1] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
