# syntax = docker/dockerfile:1

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.7
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Runtime packages: SQLite (development, tests) and the PostgreSQL client library (production)
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl ca-certificates libsqlite3-0 libpq5 procps && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    PORT="3050" \
    RAILS_SERVE_STATIC_FILES="true" \
    RAILS_LOG_TO_STDOUT="true" \
    ASSUME_SSL="true" \
    FORCE_SSL="false"


# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential pkg-config libyaml-dev libpq-dev && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times
RUN bundle exec bootsnap precompile app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile


# Development image: build tools + all gem groups, source mounted at runtime.
# Used by bin/docker-dev so nobody needs a working local Ruby toolchain.
FROM base AS dev
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential pkg-config libyaml-dev libpq-dev git && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
ENV RAILS_ENV="development" BUNDLE_DEPLOYMENT="" BUNDLE_WITHOUT="" ASSUME_SSL="false" SOLID_QUEUE_IN_PUMA="true"
EXPOSE 3050
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "3050"]


# Final stage for app image
FROM base

# Copy built artifacts: gems, application
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails

# Run and own only the runtime files as a non-root user for security
RUN useradd rails --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER rails:rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Lets Coolify/compose know when the app is actually ready to receive traffic.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/up" || exit 1

# Start the server by default, this can be overwritten at runtime
EXPOSE 3050
CMD ["./bin/rails", "server"]
