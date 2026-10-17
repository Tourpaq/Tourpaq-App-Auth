require_relative "lib/tourpaq_auth/version"

Gem::Specification.new do |spec|
  spec.name = "tourpaq_auth"
  spec.version = TourpaqAuth::VERSION
  spec.authors = [ "Tourpaq DK Tech" ]
  spec.summary = "Client for Tourpaq Auth: OIDC login, access re-checks, members sync and token introspection"
  spec.description = "Shared by the journeybooking Rails apps (Tourpaq Auth SPECS.md §13)."
  spec.homepage = "https://auth.app.journeybooking.eu"
  spec.license = "Nonstandard"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = [ "lib" ]

  # Everything else is the standard library (net/http, openssl, json, digest).
  spec.add_dependency "jwt", "~> 2.9"
end
