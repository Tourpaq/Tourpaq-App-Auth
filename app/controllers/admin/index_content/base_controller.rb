# Base of the index content screens on the ADMIN host (SPECS.md §24.3), WWW's /admin: admins only (AdminAuthentication,
# in Admin::BaseController). Every change is audited as index.<kind>.<created|updated|deleted>, with what changed
# (markdown bodies only as "changed").
class Admin::IndexContent::BaseController < Admin::BaseController
  helper Index::ContentHelper

  private

  # Saves the record and its group choices (has_many :through, written at once on assignment) together, or neither.
  def update_atomically(record, attrs)
    record.class.transaction do
      record.update(attrs) || raise(ActiveRecord::Rollback)
    end
  end

  def audit(action, record, data = {})
    AuditEvent.record("index.#{action}", subject: record, data: data)
  end

  # { "url" => [before, after], "body" => "changed" } for the last save.
  def audited_changes(record)
    record.saved_changes.except("id", "created_at", "updated_at").to_h do |key, (before, after)|
      [ key, %w[body].include?(key) ? "changed" : [ before, after ] ]
    end
  end
end
