require "net/http"
require "openssl"
require "json"
require "uri"

module TourpaqAuth
  # The default HTTP seam (Configuration#http): plain Net::HTTP, JSON accepted, forms posted, a raw body put
  # (only when the caller passes body:, so seams written before the catalogue push keep working). Returns
  # [status, body, headers] with lowercase header names. Network failures raise; callers turn them
  # into TourpaqAuth::Unavailable.
  module Http
    # What "the auth app cannot be reached" looks like from Net::HTTP.
    NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError,
                       EOFError, Net::ProtocolError ].freeze

    module_function

    # body: a raw request body (the catalogue push sends JSON with PUT); form: form fields (POST).
    def request(method, url, form: nil, headers: {}, timeout: 5, body: nil)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: timeout, read_timeout: timeout) do |http|
        request = { post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method, Net::HTTP::Get).new(uri)
        request["Accept"] = "application/json"
        request["User-Agent"] = "tourpaq_auth/#{VERSION}"
        headers.each { |name, value| request[name] = value }
        request.set_form_data(form) if form
        request.body = body if body
        response = http.request(request)
        [ response.code.to_i, response.body.to_s, response.to_hash.transform_values { _1.join(", ") } ]
      end
    end

    # "Basic …" for client_secret_basic: id and secret form-encoded, then base64 (RFC 6749 §2.3.1).
    def basic_auth(id, secret)
      "Basic " + [ "#{URI.encode_www_form_component(id)}:#{URI.encode_www_form_component(secret)}" ].pack("m0")
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      raise Error, "The auth app answered something that is not JSON"
    end

    # Header lookup that does not care about case (the fake provider and Net::HTTP differ).
    def header(headers, name)
      return nil unless headers
      headers.each { |key, value| return value if key.to_s.casecmp?(name) }
      nil
    end

    # Seconds from "Cache-Control: max-age=N", or nil.
    def max_age(headers)
      header(headers, "Cache-Control").to_s[/max-age=(\d+)/, 1]&.to_i
    end
  end
end
