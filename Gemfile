source "https://rubygems.org"

gem "rails", "~> 8.1.4"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# SQLite by default; PostgreSQL (the Tourpaq App Platform's) when DATABASE_URL is set (see config/database.yml)
gem "sqlite3", ">= 2.1"
gem "pg", "~> 1.6"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Database-backed Active Job backend: cleanup, expiry reminders, heartbeat (SPECS.md §19).
# Its tables live in the app database (one database per app on the platform), run inside Puma.
gem "solid_queue"

# Sign-in with Microsoft Entra ID (SPECS.md §3): the omniauth strategy, POST-only start with CSRF check.
gem "omniauth", "~> 2.1"
gem "omniauth-entra-id", "~> 3.1"
gem "omniauth-rails_csrf_protection", "~> 1.0"

# The OIDC provider (SPECS.md §7) is hand-rolled (no Doorkeeper, §16): RS256 ID tokens and the JWKS.
gem "jwt", "~> 2.9"

# The index's markdown (entry detail pages and docs, SPECS.md §24.3): GFM tables and fenced code, highlighted
# with Rouge, sanitised by Index::Markdown. Carried over from Tourpaq-App-WWW.
gem "kramdown", "~> 2.5"
gem "kramdown-parser-gfm", "~> 1.1"
gem "rouge", "~> 4.5"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  gem "dotenv-rails"
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end
