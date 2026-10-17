# Where the protocol endpoints' rate limits count (SPECS.md §14). Rails' rate_limit counts in a cache:
# the app's cache (a memory store: one Puma process holds every counter) in development and
# production. Tests use a cache of their own, emptied before each test (test/support/oidc_helpers.rb),
# because the test cache is a null store, which would never limit anything.
#
#   rate_limit to: 60, within: 1.minute, store: RateLimitStore.store, …
module RateLimitStore
  def self.store
    @store ||= Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
  end

  # The answer of a JSON endpoint over its limit. The Ruby client (§13) treats 429 as an outage.
  def self.json_refusal(controller)
    controller.response.set_header("Retry-After", "60")
    controller.render json: { error: "rate_limited", error_description: "Too many requests. Try again in a minute." },
                      status: :too_many_requests
  end
end
