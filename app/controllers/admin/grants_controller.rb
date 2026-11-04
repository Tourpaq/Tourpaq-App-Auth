# Sets, changes or removes a grant of an app to a user or a group (SPECS.md §5.3), from the user's or
# the group's page. POST /grants with app_id, subject_type (User | Group), subject_id, channel (web | mcp, §25;
# default web) and role (a role key, or "none" for no access: users only). DELETE /grants/:id removes it. GrantChange records
# grant.created / grant.changed / grant.removed with the before/after effective role of each
# affected user.
#
# In a multiple-roles app (§23.2) POST adds one more role to the subject ("none" replaces the user's roles with no
# access). A change that would leave the app without anybody holding its admin permission is refused.
class Admin::GrantsController < Admin::BaseController
  def create
    app = App.find(params.expect(:app_id))
    subject = find_subject
    channel = params[:channel].presence || "web"
    return refused("#{App.channel_label(channel)} is not a channel of #{app.name}.", to: subject_path(subject)) unless app.channel?(channel)
    role = params[:role].to_s == "none" ? nil : (app.role(params[:role]) or return refused("Pick a role of #{app.name}.", to: subject_path(subject)))
    grant = GrantChange.set(app: app, subject: subject, role: role, channel: channel)
    return refused(grant, to: subject_path(subject)) if grant.errors.any?
    where = app.channels.size > 1 || channel != "web" ? "#{app.name} (#{App.channel_label(channel)})" : app.name
    notice = if app.multiple_roles?
      role ? "#{where}: #{label(subject)} now holds #{role.key}." : "#{where}: #{label(subject)} now has no access."
    else
      "#{where}: #{label(subject)} now has #{role ? role.key : 'no access'}."
    end
    redirect_to subject_path(subject), notice: notice
  end

  def destroy
    grant = Grant.includes(:app, :subject, :app_role).find(params[:id])
    GrantChange.remove(grant)
    return refused(grant, to: subject_path(grant.subject)) if grant.errors.any?
    what = grant.app.multiple_roles? ? "the grant of #{grant.app_role&.key || 'no access'}" : "the grant"
    where = grant.app.channels.size > 1 || grant.channel != "web" ? "#{grant.app.name} (#{App.channel_label(grant.channel)})" : grant.app.name
    redirect_to subject_path(grant.subject), notice: "#{where}: #{what} to #{label(grant.subject)} is removed."
  end

  private

  def find_subject
    case params.expect(:subject_type)
    when "User" then User.find(params.expect(:subject_id))
    when "Group" then Group.find(params.expect(:subject_id))
    else raise ActiveRecord::RecordNotFound
    end
  end

  def subject_path(subject) = subject.is_a?(Group) ? admin_group_path(subject) : admin_user_path(subject)
  def label(subject) = subject.is_a?(Group) ? subject.name : subject.display_name
end
