# Base of the INDEX host's controllers (SPECS.md §24.1): the index host's own session through the auth
# host's OIDC provider (IndexAuthentication), layout "index". Routes: config/routes/index.rb. The index
# module's controllers inherit from this too.
class Index::BaseController < ActionController::Base
  include IndexAuthentication

  allow_browser versions: :modern
  stale_when_importmap_changes
end
