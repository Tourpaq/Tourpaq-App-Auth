# The audit log (SPECS.md §12): newest first, filtered by user (as actor or subject), app and action
# (a prefix such as "grant." or a full name). Paged by id.
class Admin::AuditEventsController < Admin::BaseController
  PER_PAGE = 100

  def index
    scope = AuditEvent.includes(:actor, :subject, :app).recent_first
    if params[:user_id].present?
      scope = scope.where(actor_id: params[:user_id]).or(scope.where(subject_type: "User", subject_id: params[:user_id]))
    end
    scope = scope.where(app_id: params[:app_id]) if params[:app_id].present?
    if params[:event].present?
      scope = scope.where("audit_events.action LIKE ?", "#{AuditEvent.sanitize_sql_like(params[:event].to_s.strip)}%")
    end
    scope = scope.where(id: ...params[:before].to_i) if params[:before].present?
    @events = scope.limit(PER_PAGE + 1).to_a
    @next_before = @events.pop.then { @events.last.id } if @events.size > PER_PAGE
    @users = User.ordered.to_a
    @apps = App.ordered.to_a
    @actions = AuditEvent.distinct.order(:action).pluck(:action)
  end
end
