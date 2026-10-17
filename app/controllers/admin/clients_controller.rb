# An app's OAuth/OIDC clients (SPECS.md §7.4): web (confidential, secrets) or extension (public,
# PKCE), with exact redirect URIs. The client id cannot change. Audited client.created /
# client.updated / client.disabled / client.enabled.
class Admin::ClientsController < Admin::BaseController
  before_action :set_app
  before_action :set_client, only: %i[show edit update]

  def show
    @secrets = @client.client_secrets.includes(:created_by).order(:created_at).to_a
  end

  def new
    @client = @app.clients.build(kind: "web", client_id: "#{@app.slug}-web", name: "#{@app.name} web")
  end

  def create
    @client = @app.clients.build(params.expect(client: %i[client_id kind name redirect_uris post_logout_redirect_uris]))
    if Client::KINDS.excluding("internal").exclude?(@client.kind)
      @client.errors.add(:kind, "must be web or extension")
      return render(:new, status: :unprocessable_entity)
    end
    if @client.save
      AuditEvent.record("client.created", subject: @client, app: @app,
                        data: { client_id: @client.client_id, kind: @client.kind, redirect_uris: @client.redirect_uris })
      redirect_to admin_app_client_path(@app, @client), notice: "Client #{@client.client_id} is created.#{' Create its secret now.' if @client.web?}"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attrs = params.expect(client: %i[name redirect_uris post_logout_redirect_uris])
    disabled = params.dig(:client, :disabled) == "1"
    attrs[:disabled_at] = disabled ? (@client.disabled_at || Time.current) : nil
    if @client.update(attrs)
      changes = @client.saved_changes.except("updated_at", "disabled_at").transform_values(&:last)
      AuditEvent.record("client.updated", subject: @client, app: @app, data: { changes: changes }) if changes.any?
      if @client.saved_change_to_disabled_at?
        AuditEvent.record(@client.disabled_at ? "client.disabled" : "client.enabled", subject: @client, app: @app)
      end
      redirect_to admin_app_client_path(@app, @client), notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def set_client
    @client = @app.clients.find(params[:id])
  end
end
