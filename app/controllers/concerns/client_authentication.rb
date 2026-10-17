# OAuth client authentication for the protocol's machine endpoints (SPECS.md §7.4, §8, §9.2):
# /oauth/token, /oauth/revoke, /oauth/introspect and /api/v1/*.
#
#   client_secret_basic   Authorization: Basic base64(urlencode(client_id):urlencode(secret))
#   client_secret_post    client_id and client_secret in the form body
#   none                  client_id only: public (extension) clients, where an action allows it
#
# Web clients must present an active secret (either of their two). Extension clients must present
# none. The internal clients ("admin", "index") are never accepted over HTTP: their code exchange happens in-process.
# A disabled client, or a client of a disabled app, is refused like an unknown one.
#
#   before_action -> { authenticate_client!(public: true) }
#   Current.client   # the authenticated Client
module ClientAuthentication
  extend ActiveSupport::Concern

  private

  # [client_id, secret, method]; method nil when the request mixes methods (refused).
  def client_credentials
    @client_credentials ||= begin
      header = request.authorization.to_s
      if header.match?(/\ABasic /i)
        decoded = Base64.decode64(header.split(" ", 2).last.to_s)
        id, secret = decoded.split(":", 2)
        id = URI.decode_www_form_component(id.to_s.force_encoding(Encoding::UTF_8))
        secret = URI.decode_www_form_component(secret.to_s.force_encoding(Encoding::UTF_8))
        id = secret = "" unless id.valid_encoding? && secret.valid_encoding? # garbage, not a 500
        params[:client_secret].present? ? [ id, secret, nil ] : [ id, secret, :basic ]
      elsif params[:client_secret].present?
        [ params[:client_id].to_s, params[:client_secret].to_s, :post ]
      else
        [ params[:client_id].to_s, nil, :none ]
      end
    rescue ArgumentError
      [ nil, nil, nil ]
    end
  end

  # The client id the request claims (for rate limits), before it is authenticated.
  def claimed_client_id = client_credentials.first.to_s.presence

  def authenticate_client!(public: false)
    id, secret, method = client_credentials
    return refuse_client("Use one client authentication method") if method.nil?
    client = Client.find_active(id)
    client = nil if client && !client.active?

    authenticated =
      if client.nil? || client.internal? then nil
      elsif client.web? then (secret.present? && client.authenticate_secret(secret)) ? client : nil
      elsif client.extension? then (public && method == :none) ? client : nil
      end
    return refuse_client("Client authentication failed") unless authenticated
    Current.client = authenticated
  end

  def refuse_client(description)
    response.set_header("WWW-Authenticate", %(Basic realm="#{AuthHosts.auth_host}"))
    render json: { error: "invalid_client", error_description: description }, status: :unauthorized
  end

  def render_oauth_error(error)
    render json: error.to_h, status: error.status
  end

  def no_store!
    response.set_header("Cache-Control", "no-store")
    response.set_header("Pragma", "no-cache")
  end
end
