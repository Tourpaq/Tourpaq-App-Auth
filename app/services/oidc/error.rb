# An OAuth/OIDC protocol error (RFC 6749 §5.2, §4.1.2.1): an error code the client understands, a
# description for people, and the HTTP status the token endpoints answer with.
#
#   raise Oidc::Error.new("invalid_grant", "The code has expired")
module Oidc
  class Error < StandardError
    attr_reader :code, :description, :status

    def initialize(code, description = nil, status: nil)
      @code = code.to_s
      @description = description
      @status = status || (@code == "invalid_client" ? :unauthorized : :bad_request)
      super(description || @code)
    end

    def to_h = { error: code, error_description: description }.compact
  end
end
