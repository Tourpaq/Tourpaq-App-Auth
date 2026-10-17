module TourpaqAuth
  # Calls to the auth app's authorization API and introspection endpoint, authenticated as the app's web
  # client with client_secret_basic (SPECS.md §8, §9.2), at LOGIN_INTERNAL_URL when set, else LOGIN_ISSUER. Network failures, timeouts, 5xx and 429 raise
  # TourpaqAuth::Unavailable; other statuses are returned for the caller to judge.
  module Api
    module_function

    def call(method, path, form: nil, headers: {}, body: nil)
      config = TourpaqAuth.config
      raise NotConfigured, "Tourpaq Auth is not configured (LOGIN_ISSUER, LOGIN_CLIENT_ID, LOGIN_CLIENT_SECRET)" unless config.enabled?

      headers = { "Authorization" => Http.basic_auth(config.client_id, config.client_secret) }.merge(headers)
      options = { form: form, headers: headers, timeout: config.http_timeout }
      options[:body] = body if body
      status, body, response_headers = config.http.call(method, config.backchannel_endpoint(path), **options)
      status = status.to_i
      raise Unavailable, "The auth app answered #{status}" if status >= 500 || status == 429
      [ status, body, response_headers || {} ]
    rescue *Http::NETWORK_ERRORS => e
      raise Unavailable, "The auth app cannot be reached (#{e.class})"
    end

    # A refusal that is not an outage: wrong client credentials, a disabled app, a bad request. Raises
    # TourpaqAuth::Refused (a TourpaqAuth::Error) with the status.
    def refused!(status, body)
      json = begin
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end
      reason = json.is_a?(Hash) ? (json["error_description"] || json["error"]) : nil
      raise Refused.new("The auth app refused the request (#{status}#{reason ? ": #{reason}" : ''})", status: status.to_i)
    end
  end
end
