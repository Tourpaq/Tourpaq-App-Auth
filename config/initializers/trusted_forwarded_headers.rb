# X-Forwarded-* only from the proxy: lib/rack_ext/trusted_forwarded_headers.rb. First in the stack,
# before host authorization, SSL and RemoteIp read those headers.
require Rails.root.join("lib/rack_ext/trusted_forwarded_headers")

Rails.application.config.middleware.insert_before 0, TrustedForwardedHeaders

# The back-channel hosts (AUTH_INTERNAL_HOSTS) answer only the server-to-server endpoints:
# lib/rack_ext/internal_host_gate.rb. After the forwarded headers are settled, before OmniAuth and the router.
require Rails.root.join("lib/rack_ext/internal_host_gate")

Rails.application.config.middleware.insert_after TrustedForwardedHeaders, InternalHostGate
