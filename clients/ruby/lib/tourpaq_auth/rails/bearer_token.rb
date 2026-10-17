require "active_support/concern"

module TourpaqAuth
  module Rails
    # Reads "Authorization: Bearer <token>", introspects it with the auth app (SPECS.md §9.2) and exposes
    # the answer as tourpaq_auth_token (a TourpaqAuth::Tokens::Result, or nil without a header).
    #
    #   class Api::BaseController < ActionController::API
    #     include TourpaqAuth::Rails::BearerToken
    #     require_tourpaq_auth_token                        # 401 unless the token is active
    #     require_tourpaq_auth_token write: true, only: %i[create update destroy]   # 403 unless read_write
    #     require_tourpaq_auth_token scope: "all", only: :internal_comments        # 403 unless that scope
    #                                        # (an app's own scopes, SPECS.md §23.3: the Dashboard's public < all)
    #
    #     def current_user = @current_user ||= User.find_by!(auth_sub: tourpaq_auth_token.sub)
    #   end
    #
    # The scope is capped by the role in the app (SPECS.md §9.2): check tourpaq_auth_token.role too, or for a
    # permission app tourpaq_auth_token.permission?(key).
    # Override tourpaq_auth_token_refused / tourpaq_auth_token_unavailable to answer differently.
    module BearerToken
      extend ActiveSupport::Concern

      class_methods do
        def require_tourpaq_auth_token(write: false, scope: nil, **options)
          before_action(**options) { require_tourpaq_auth_token!(write: write, scope: scope) }
        end
      end

      private

      # The token from the Authorization header, or nil.
      def tourpaq_auth_bearer
        header = request.authorization.to_s
        token = header[/\ABearer[ ]+(\S+)\s*\z/i, 1]
        token unless token.nil? || token.empty?
      end

      # The introspection result for the request's bearer token (memoised), or nil without one.
      def tourpaq_auth_token
        return @tourpaq_auth_token if defined?(@tourpaq_auth_token)
        bearer = tourpaq_auth_bearer
        @tourpaq_auth_token = bearer && TourpaqAuth::Tokens.introspect(bearer)
      end

      def require_tourpaq_auth_token!(write: false, scope: nil)
        result = tourpaq_auth_token
        return tourpaq_auth_token_refused(result ? :invalid_token : :missing_token) unless result&.active?
        if write && !result.read_write?
          @tourpaq_auth_required_scope = "read_write"
          tourpaq_auth_token_refused(:insufficient_scope)
        elsif scope && !result.scope?(scope)
          @tourpaq_auth_required_scope = Array(scope).join(" ")
          tourpaq_auth_token_refused(:insufficient_scope)
        end
      rescue TourpaqAuth::NotConfigured
        tourpaq_auth_token_refused(:invalid_token)
      rescue TourpaqAuth::Error => e
        TourpaqAuth.log(:warn, "token introspection failed: #{e.message}")
        tourpaq_auth_token_unavailable
      end

      # :missing_token, :invalid_token (401) or :insufficient_scope (403), as in RFC 6750 §3.
      def tourpaq_auth_token_refused(reason)
        if reason == :insufficient_scope
          required = @tourpaq_auth_required_scope || "read_write"
          response.headers["WWW-Authenticate"] = %(Bearer error="insufficient_scope", scope="#{required}")
          description = required == "read_write" ? "This token may only read." : "This token's scope does not allow this (needs #{required})."
          render json: { error: "insufficient_scope", error_description: description }, status: :forbidden
        else
          response.headers["WWW-Authenticate"] = reason == :missing_token ? "Bearer" : %(Bearer error="invalid_token")
          render json: { error: reason == :missing_token ? "unauthorized" : "invalid_token",
                         error_description: "A valid Tourpaq Auth token is required." }, status: :unauthorized
        end
      end

      def tourpaq_auth_token_unavailable
        response.headers["Retry-After"] = "30"
        render json: { error: "temporarily_unavailable", error_description: "The token cannot be checked right now." },
               status: :service_unavailable
      end
    end
  end
end
