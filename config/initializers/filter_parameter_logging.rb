# Parameters filtered from the logs (partial match: "token" also covers refresh_token, id_token,
# access_token, token_hint). Secrets are never logged (SPECS.md §14): client secrets, tokens,
# authorization codes and PKCE verifiers, session tokens, passwords. The Authorization header is
# never logged by Rails; Rails::Rack::Logger logs the path through request.filtered_path, so query
# strings (?code=…) are filtered too.
Rails.application.config.filter_parameters += [
  :token, :client_secret, :code, :refresh_token, :authorization, :secret, :password,
  :passw, :_key, :crypt, :salt, :certificate, :otp, :assertion, :nonce, :verifier
]
