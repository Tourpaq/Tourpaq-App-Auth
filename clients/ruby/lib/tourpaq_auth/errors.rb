module TourpaqAuth
  # Anything that goes wrong talking to the auth app or with its tokens. Messages are safe to show to
  # the person signing in: they never contain a token, code or secret.
  class Error < StandardError; end

  # The gem is used without LOGIN_ISSUER, LOGIN_CLIENT_ID and LOGIN_CLIENT_SECRET.
  class NotConfigured < Error; end

  # The auth app could not be reached, timed out or answered 5xx/429, and no usable last known answer
  # was available (the access check's grace period, SPECS.md §8.3).
  class Unavailable < Error; end

  # The auth app answered, and refused: 401 invalid_client (wrong or deleted secret, a disabled client or
  # app), 403, 400 or another status that is not an outage (SPECS.md §13). Not covered by the grace period.
  class Refused < Error
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end
  end

  # The login could not be completed: wrong state, expired login, invalid ID token, refused code.
  class LoginError < Error; end
end
