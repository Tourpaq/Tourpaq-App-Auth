# Groups (SPECS.md §5.2, §11.2): name, description, Tourpaq staff or not (who sees the index's content for all staff,
# §24.3), members, and a grant per app. Audited
# group.created / group.updated / group.deleted; deleting a group removes its grants first, each
# audited grant.removed with the members' before/after roles.
class Admin::GroupsController < Admin::BaseController
  before_action :set_group, except: %i[index new create]

  def index
    @groups = Group.ordered.includes(:users, grants: %i[app app_role]).to_a
  end

  def show
    @members = @group.users.ordered.to_a
    @non_members = User.active.ordered.where.not(id: @members.map(&:id))
    @apps = App.ordered.includes(:roles).to_a
    @grants = @group.grants.includes(:app_role).group_by(&:app_id)
  end

  def new
    @group = Group.new
  end

  def create
    @group = Group.new(group_params)
    if @group.save
      AuditEvent.record("group.created", subject: @group, data: { name: @group.name, staff: @group.staff })
      redirect_to admin_group_path(@group), notice: "Group #{@group.name} is created. Add members and give it access."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @group.update(group_params)
      changes = @group.saved_changes.except("updated_at").transform_values(&:last)
      AuditEvent.record("group.updated", subject: @group, data: { changes: changes }) if changes.any?
      redirect_to admin_group_path(@group), notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Refused (nothing changes) when removing its grants would leave an app without anybody holding its admin
  # permission (AppAdminGuard, §23.2).
  def destroy
    refusal = nil
    Group.transaction do
      @group.grants.includes(:app, :app_role).each do |grant|
        GrantChange.remove(grant)
        next if grant.errors.empty?
        refusal = grant.errors.full_messages.to_sentence
        raise ActiveRecord::Rollback
      end
      members = @group.users.pluck(:email)
      @group.destroy!
      AuditEvent.record("group.deleted", subject: @group, data: { name: @group.name, members: members })
    end
    return refused(refusal, to: admin_group_path(@group)) if refusal
    redirect_to admin_groups_path, notice: "Group #{@group.name} is deleted."
  end

  private

  def set_group
    @group = Group.find(params[:id])
  end

  def group_params = params.expect(group: %i[name description staff])
end
