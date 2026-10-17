require "jwt"
require "net/http"

module OmniAuth
  # Verifies an Entra ID token (SPECS.md §3.1 step 3): RS256 signature against the tenant's JWKS,
  # iss, aud = our client id, exp/nbf (with leeway), nonce, and tid = ENTRA_TENANT_ID.
  # Raises EntraIdToken::Invalid with a short reason; returns the claims (string keys).
  #
  # The JWKS is fetched from Entra and cached in-process; an unknown kid refetches it at most once
  # every REFETCH_AFTER. Tests replace the fetcher: OmniAuth::EntraIdToken.jwks_fetcher = ->(url) { hash }.
  class EntraIdToken
    class Invalid < StandardError; end

    BASE_URL = "https://login.microsoftonline.com".freeze
    REFETCH_AFTER = 5 * 60

    class << self
      attr_writer :jwks_fetcher

      def jwks_fetcher = @jwks_fetcher ||= method(:fetch_jwks)

      def jwks_url(tenant_id) = "#{BASE_URL}/#{tenant_id}/discovery/v2.0/keys"
      def issuer(tenant_id) = "#{BASE_URL}/#{tenant_id}/v2.0"

      def verify!(id_token, tenant_id:, client_id:, nonce:, leeway: 60)
        raise Invalid, "no ID token" if id_token.blank?
        raise Invalid, "ENTRA_TENANT_ID is not set" if tenant_id.blank?
        raise Invalid, "no nonce was stored for this sign-in" if nonce.blank?

        claims, _header = JWT.decode(id_token, nil, true,
          algorithms: [ "RS256" ], jwks: jwks_loader(tenant_id),
          iss: issuer(tenant_id), verify_iss: true,
          aud: client_id, verify_aud: true,
          verify_expiration: true, verify_not_before: true, leeway: leeway)

        unless ActiveSupport::SecurityUtils.secure_compare(claims["nonce"].to_s, nonce.to_s)
          raise Invalid, "nonce does not match"
        end
        raise Invalid, "wrong tenant" unless claims["tid"].to_s.casecmp?(tenant_id.to_s)
        raise Invalid, "no oid claim" if claims["oid"].blank?
        claims
      rescue JWT::ExpiredSignature
        raise Invalid, "ID token expired"
      rescue JWT::InvalidIssuerError
        raise Invalid, "wrong issuer (tenant)"
      rescue JWT::InvalidAudError
        raise Invalid, "wrong audience"
      rescue JWT::DecodeError => e
        raise Invalid, "ID token rejected: #{e.message}"
      end

      def reset_cache! = (@cache = {})

      private

      # JWT's jwks loader: called with kid_not_found: true on an unknown kid.
      def jwks_loader(tenant_id)
        lambda do |options|
          @cache ||= {}
          entry = @cache[tenant_id]
          stale = entry.nil? || (options[:kid_not_found] && entry[:at] < Time.now.to_i - REFETCH_AFTER)
          if stale
            entry = { keys: jwks_fetcher.call(jwks_url(tenant_id)), at: Time.now.to_i }
            @cache[tenant_id] = entry
          end
          entry[:keys]
        end
      end

      def fetch_jwks(url)
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { _1.get(uri.request_uri) }
        raise Invalid, "Entra JWKS answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, JSON::ParserError => e
        raise Invalid, "Entra JWKS cannot be fetched (#{e.class})"
      end
    end
  end
end
