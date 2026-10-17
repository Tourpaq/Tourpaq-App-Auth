require "omniauth/strategies/entra_id"
require_relative "../entra_id_token"

module OmniAuth
  module Strategies
    # omniauth-entra-id, tightened for SPECS.md §3.1:
    # - PKCE S256 (omniauth-oauth2's pkce option) and state (omniauth-oauth2) on every sign-in;
    # - a nonce, sent with the authorization request and checked in the ID token;
    # - the ID token's signature verified against Entra's JWKS, and tid = ENTRA_TENANT_ID
    #   (OmniAuth::EntraIdToken). Only ID-token claims are used: the access token (for Graph) is
    #   never decoded or trusted;
    # - prompt and scope never come from the browser's request (omniauth-entra-id copies both from it):
    #   prompt=login is sent when the Rails session asks for a fresh sign-in ("entra_prompt", set by
    #   Authentication#request_sign_in), and the callback then checks Entra's auth_time (SPECS.md §3.1);
    # - the redirect_uri is ENTRA_REDIRECT_URI (SPECS.md §24.2), the same in the authorization request and the
    #   code exchange as Entra requires, and never from the request's host. While the registration only has
    #   home.app's callback, it is that URL and the Dashboard forwards the GET (query kept) to our callback;
    # - response_mode=query, so the answer is a plain top-level GET that such a forward can pass on, and our
    #   host-only, SameSite=Lax session cookie (state, nonce, PKCE verifier) comes with it;
    # - the state starts with STATE_PREFIX ("tpa."), so a forward in front of home.app can tell OUR answers from
    #   the old Dashboard's, which share the same registered redirect URI until the Dashboard is cut over: the
    #   Traefik rule in docker-compose.yaml forwards only states with this prefix (SPECS.md §24.2). The prefix
    #   is not a secret; the state is still compared in full against the session.
    # Its name stays "entra_id", so the paths are /auth/entra_id and /auth/entra_id/callback.
    class TourpaqEntraId < EntraId
      option :name, "entra_id"
      option :pkce, true

      NONCE_KEY = "omniauth.entra_id.nonce".freeze

      PROMPT_KEY = "entra_prompt".freeze

      STATE_PREFIX = "tpa.".freeze

      def authorize_params
        super.tap do |params|
          # omniauth-oauth2 has just put a random state in params and the session; mark both the same way.
          state = "#{STATE_PREFIX}#{params[:state]}"
          params[:state] = state
          session["omniauth.state"] = state
          nonce = SecureRandom.urlsafe_base64(32)
          session[NONCE_KEY] = nonce
          params[:nonce] = nonce
          params.delete("prompt")
          params.delete(:prompt)
          params[:prompt] = "login" if session[PROMPT_KEY].to_s == "login"
          params[:scope] = options.scope.presence || DEFAULT_SCOPE
          params[:response_mode] = "query"
        end
      end

      # omniauth-oauth2 sends this as redirect_uri in the authorization request (request_phase) and in the
      # token request (build_access_token).
      def callback_url
        Rails.configuration.x.auth.entra_redirect_uri.presence || (full_host + callback_path)
      end

      def raw_info
        @raw_info ||= OmniAuth::EntraIdToken.verify!(
          access_token.params["id_token"],
          tenant_id: options.tenant_id, client_id: options.client_id,
          nonce: session.delete(NONCE_KEY), leeway: options.jwt_leeway
        )
      rescue OmniAuth::EntraIdToken::Invalid => e
        # omniauth-oauth2 turns a CallbackError into a failure (OmniAuth.config.on_failure).
        raise CallbackError.new(:invalid_id_token, e.message)
      end

      info do
        {
          name: raw_info["name"],
          email: raw_info["email"].presence || raw_info["preferred_username"],
          nickname: raw_info["preferred_username"]
        }
      end
    end
  end
end
