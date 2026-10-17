# Base of the ADMIN host's controllers (SPECS.md §11.2): admin network check, the admin session and
# an active admin on every request (AdminAuthentication). Routes: config/routes/admin.rb.
class Admin::BaseController < ActionController::Base
  include AdminAuthentication

  allow_browser versions: :modern
  stale_when_importmap_changes

  private

  # Redirects back with the validation messages of a refused change (e.g. the last active admin).
  def refused(record_or_message, to:)
    message = record_or_message.respond_to?(:errors) ? record_or_message.errors.full_messages.to_sentence : record_or_message.to_s
    redirect_to to, alert: message.presence || "That change was refused."
  end
end
