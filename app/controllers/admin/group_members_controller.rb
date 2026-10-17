# Adds a user to a group or removes them (SPECS.md §5.2), from the group's page
# (POST /groups/:group_id/members with user_id) or the user's page (POST /users/:user_id/groups with
# group_id; back=user returns there). Audited group.member_added / group.member_removed with the user's
# before/after effective role in every app the group has a grant for. Removing a member is refused when it
# would leave an app without anybody holding its admin permission (AppAdminGuard, §23.2).
class Admin::GroupMembersController < Admin::BaseController
  before_action :set_group

  def create
    user = User.find(params.expect(:user_id))
    if @group.users.exists?(user.id)
      return redirect_to(back_path(user), alert: "#{user.display_name} is already in #{@group.name}.")
    end
    change("group.member_added", user) { @group.group_memberships.create!(user: user) }
    redirect_to back_path(user), notice: "#{user.display_name} is added to #{@group.name}."
  end

  def destroy
    membership = @group.group_memberships.find_by!(user_id: params[:id])
    user = membership.user
    change("group.member_removed", user) { membership.destroy! }
    redirect_to back_path(user), notice: "#{user.display_name} is removed from #{@group.name}."
  rescue AppAdminGuard::LastAdmin => e
    refused(e.message, to: back_path(user))
  end

  private

  def set_group
    @group = Group.find(params[:group_id])
  end

  def change(action, user, &block)
    apps = App.where(id: @group.grants.select(:app_id)).to_a
    GroupMembership.transaction do
      entries = AccessChange.track(users: [ user ], apps: apps) { AppAdminGuard.protect(apps, &block) }
      AuditEvent.record(action, subject: @group,
                        data: { user_id: user.id, email: user.email, access: AccessChange.audit_data(entries.select(&:changed?), with_app: true) })
    end
  end

  def back_path(user) = params[:back] == "user" ? admin_user_path(user) : admin_group_path(@group)
end
