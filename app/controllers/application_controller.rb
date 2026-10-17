# Base of the AUTH host's controllers: sign-in required (Authentication) unless a controller says
# allow_unauthenticated_access. Index controllers inherit from Index::BaseController, admin controllers from
# Admin::BaseController instead.
class ApplicationController < ActionController::Base
  include Authentication

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes
end
