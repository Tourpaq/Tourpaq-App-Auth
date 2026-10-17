require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module TourpaqAuth
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # lib/omniauth (the Entra strategy) and lib/rack_ext (middleware) are loaded once, explicitly:
    # middleware must not hold reloadable constants.
    config.autoload_lib(ignore: %w[assets tasks omniauth rack_ext])

    # Timestamps are UTC in storage; views display Europe/Copenhagen (ApplicationHelper#local_time).
    config.time_zone = "UTC"

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
