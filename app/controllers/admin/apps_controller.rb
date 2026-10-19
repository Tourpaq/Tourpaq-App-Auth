# Apps (SPECS.md §5.1, §11.2): details, roles, clients, members and the token count. A new app gets
# its roles from a list (lowest first); roles are managed on the app's page afterwards
# (Admin::AppRolesController). Audited app.created / app.updated / app.disabled / app.enabled.
#
# Settings of §23.2/§23.3: multiple roles, the admin permission (last-administrator guard) and the ordered
# token scopes. A multiple-roles app's page also shows its pushed permission catalogue and flags role keys the
# catalogue does not know.
class Admin::AppsController < Admin::BaseController
  before_action :set_app, except: %i[index new create]

  def index
    @apps = App.ordered.includes(:roles, :clients).to_a
    @member_counts = @apps.to_h { [ _1.id, EffectiveRole.members_of(_1).size ] }
    @token_counts = PersonalToken.active.group(:app_id).count
  end

  def show
    @clients = @app.clients.ordered.includes(:client_secrets).to_a
    @grants = @app.grants.includes(:subject, :app_role).sort_by { [ _1.subject_type, _1.subject.try(:name) || _1.subject.try(:email) || "" ] }
    @member_count = EffectiveRole.members_of(@app).size
    @token_count = @app.personal_tokens.active.count
    @roles_in_use = Grant.where(app_role_id: @app.roles.map(&:id)).group(:app_role_id).count
    @unknown = @app.unknown_permissions
    @catalogue_groups = @app.catalogue.group_by(&:display_group)
    @starter_roles = StarterRoles.missing(@app)
    @starter_admin_group = Group.find_by(name: StarterRoles::ADMIN_GROUP) if @starter_roles.include?(StarterRoles.admin_role(@app))
  end

  def members
    @members = EffectiveRole.members_of(@app)
  end

  def new
    @app = App.new(show_in_launcher: true)
    @role_list = "viewer\nadmin"
  end

  def create
    @app = App.new(app_params)
    @role_list = params.dig(:app, :role_list).to_s
    # Role names of a multiple-roles app may hold spaces ("Finance readers"): one per line there.
    keys = if @app.multiple_roles?
      @role_list.split(/\r?\n/).map { _1.strip.squeeze(" ") }.reject(&:blank?).uniq { _1.downcase }
    else
      @role_list.split(/[\s,]+/).map { _1.strip.downcase }.reject(&:blank?).uniq
    end
    keys.each_with_index { |key, i| @app.roles.build(key: key, position: i + 1) }
    if @app.save
      AuditEvent.record("app.created", subject: @app, data: { slug: @app.slug, name: @app.name, roles: @app.role_keys,
                                                              multiple_roles: @app.multiple_roles?, token_scopes: @app.token_scopes })
      redirect_to admin_app_path(@app), notice: "#{@app.name} is created. Add its web client next."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    attrs = app_params.except(:slug)
    disabled = params.dig(:app, :disabled) == "1"
    attrs[:disabled_at] = disabled ? (@app.disabled_at || Time.current) : nil
    if @app.update(attrs)
      changes = @app.saved_changes.except("updated_at", "disabled_at").transform_values(&:last)
      AuditEvent.record("app.updated", subject: @app, data: { changes: changes }) if changes.any?
      if @app.saved_change_to_disabled_at?
        AuditEvent.record(@app.disabled? ? "app.disabled" : "app.enabled", subject: @app)
      end
      redirect_to admin_app_path(@app), notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_app
    @app = App.includes(:roles).find(params[:id])
  end

  def app_params = params.expect(app: %i[slug name description icon url role_claim show_in_launcher multiple_roles admin_permission token_scope_list])
end
