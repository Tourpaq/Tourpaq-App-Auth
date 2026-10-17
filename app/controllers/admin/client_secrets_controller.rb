# A web client's secrets (SPECS.md §7.4): generated here, shown once, at most two active at a time
# (rotation: create the new one, deploy the app with it, delete the old one). Optional expiry; the
# UI warns 30 days ahead. Client#generate_secret! audits client.secret_created; deleting is audited
# client.secret_deleted here.
class Admin::ClientSecretsController < Admin::BaseController
  EXPIRY_CHOICES = { "never" => nil, "90" => 90, "365" => 365, "730" => 730 }.freeze

  before_action :set_client

  # Renders the plain secret once (not a redirect: it is never stored, nor put in the flash).
  def create
    days = EXPIRY_CHOICES.fetch(params[:expires_in_days].to_s, 365)
    @secret_plain = @client.generate_secret!(expires_at: days&.days&.from_now, created_by: current_admin)
    @secret = @client.client_secrets.order(:id).last
    response.headers["Cache-Control"] = "no-store"
    render :show
  rescue Client::TooManySecrets, ArgumentError => e
    refused(e.message, to: admin_app_client_path(@app, @client))
  end

  def destroy
    secret = @client.client_secrets.find(params[:id])
    secret.destroy!
    AuditEvent.record("client.secret_deleted", subject: @client, app: @app,
                      data: { hint: secret.hint, expires_at: secret.expires_at&.utc&.iso8601, last_used_at: secret.last_used_at&.utc&.iso8601 }.compact)
    redirect_to admin_app_client_path(@app, @client), notice: "Secret #{secret.hint}… is deleted. Apps still using it can no longer sign in."
  end

  private

  def set_client
    @app = App.find(params[:app_id])
    @client = @app.clients.find(params[:client_id])
  end
end
