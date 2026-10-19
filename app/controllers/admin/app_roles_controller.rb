# An app's ordered roles (SPECS.md §5.1): add one (at the top), edit its description, remove one
# that no grant uses, and reorder them after a preview of whose effective role changes.
# Audited app.role_added / app.role_changed / app.role_removed / app.roles_reordered.
#
# In a multiple-roles app (§23.2) a role is a permission set: the role editor (edit) shows the app's pushed
# catalogue as checkboxes grouped by group label, "*" for everything, and keys the catalogue does not know in red
# (kept until unticked). Saving goes through the per-app last-administrator guard (AppAdminGuard).
# `starter` adds the app's ready-made roles (StarterRoles) that it does not have yet, and with admin_group=1 gives
# DK Tech the admin one.
class Admin::AppRolesController < Admin::BaseController
  before_action :set_app

  def create
    role = @app.roles.build(key: params.dig(:role, :key), description: params.dig(:role, :description).presence,
                            position: (@app.roles.maximum(:position) || 0) + 1)
    if role.save
      AuditEvent.record("app.role_added", subject: @app, data: { key: role.key, description: role.description, order: @app.reload.role_keys })
      if @app.multiple_roles?
        redirect_to edit_admin_app_role_path(@app, role), notice: "Role #{role.key} is added. Choose its permissions."
      else
        redirect_to admin_app_path(@app), notice: "Role #{role.key} is added at the top. Move it if it belongs lower."
      end
    else
      @app.roles.reset
      refused(role, to: admin_app_path(@app))
    end
  end

  # POST: the starter roles the app does not have yet; existing roles are never touched.
  def starter
    return refused("#{@app.name} has no standard roles.", to: admin_app_path(@app)) if StarterRoles.for(@app).empty?
    group = Group.find_by(name: StarterRoles::ADMIN_GROUP) if params[:admin_group] == "1"
    result = StarterRoles.create!(@app, admin_group: group)
    if result.grant&.errors&.any?
      return refused("The roles are added, but #{group.name} could not be given #{StarterRoles.admin_role(@app).key}: " \
                     "#{result.grant.errors.full_messages.to_sentence}", to: admin_app_path(@app))
    end
    notice = result.created.any? ? "Added #{result.created.map(&:key).to_sentence}." : "#{@app.name} already has the standard roles."
    notice += " #{group.name} now has #{StarterRoles.admin_role(@app).key}." if result.grant
    redirect_to admin_app_path(@app), notice: notice
  end

  # The role editor (multiple-roles apps: description and permissions).
  def edit
    @role = @app.roles.find(params[:id])
    @catalogue_groups = @app.catalogue.group_by(&:display_group)
    known = @app.catalogue_keys.to_set
    @unknown = @app.catalogue_pushed? ? @role.unknown_permissions : []
    # Before the first push every key is "other": shown as checkboxes so they can be unticked.
    @other = @role.permissions.reject { _1 == AppRole::WILDCARD || known.include?(_1) }
    @grant_count = @role.grants.count
  end

  def update
    role = @app.roles.find(params[:id])
    back = @app.multiple_roles? ? edit_admin_app_role_path(@app, role) : admin_app_path(@app)
    attrs = { description: params.dig(:role, :description).to_s.strip.presence }
    attrs[:permissions] = permissions_param if @app.multiple_roles? && params[:role]&.key?(:permissions)
    before = role.permissions

    saved = AppAdminGuard.protect(@app) { role.update(attrs) }
    return refused(role, to: back) unless saved

    changes = role.saved_changes.except("updated_at")
    if changes.any?
      data = { key: role.key, description: role.description }
      if changes.key?("permissions")
        data[:permissions_added] = role.permissions - before
        data[:permissions_removed] = before - role.permissions
        data[:unknown] = role.unknown_permissions
      end
      AuditEvent.record("app.role_changed", subject: @app, data: data)
    end
    redirect_to @app.multiple_roles? ? admin_app_path(@app) : back, notice: "Role #{role.key} is saved."
  rescue AppAdminGuard::LastAdmin => e
    refused(e.message, to: back)
  end

  def destroy
    role = @app.roles.find(params[:id])
    return refused("#{role.key} is used by #{pluralize_grants(role)}: give those a different role first.", to: admin_app_path(@app)) if role.in_use?
    return refused("#{@app.name} needs at least one role.", to: admin_app_path(@app)) if @app.roles.size <= 1 && !@app.multiple_roles?
    role.destroy!
    AuditEvent.record("app.role_removed", subject: @app, data: { key: role.key, permissions: role.permissions, order: @app.reload.role_keys }.compact_blank)
    redirect_to admin_app_path(@app), notice: "Role #{role.key} is removed."
  end

  # GET: the new order (keys[], lowest first) and whose effective role it would change.
  def reorder
    @keys = order_param or return refused("Give every role of #{@app.name} once.", to: admin_app_path(@app))
    @changes = RoleReorder.preview(@app, @keys)
  end

  # PATCH: saves the order the preview showed.
  def apply_reorder
    keys = order_param or return refused("Give every role of #{@app.name} once.", to: admin_app_path(@app))
    changes = RoleReorder.apply!(@app, keys)
    redirect_to admin_app_path(@app), notice: "The roles of #{@app.name} are reordered; #{helpers.pluralize(changes.size, 'user')}' effective role changed."
  end

  private

  def set_app
    @app = App.includes(:roles).find(params[:app_id])
  end

  # Ticked checkboxes (role[permissions][]) plus keys typed one per line (role[extra_permissions]).
  def permissions_param
    ticked = Array(params.dig(:role, :permissions)).map(&:to_s)
    typed = params.dig(:role, :extra_permissions).to_s.split(/[\s,]+/)
    AppRole.normalize_permissions(ticked + typed)
  end

  def order_param
    keys = Array(params[:keys]).map(&:to_s)
    keys if keys.sort == @app.role_keys.sort && keys.size == @app.role_keys.size
  end

  def pluralize_grants(role) = helpers.pluralize(role.grants.count, "grant")
end
