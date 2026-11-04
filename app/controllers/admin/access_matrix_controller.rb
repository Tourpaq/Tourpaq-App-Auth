# Users × apps with each effective role (SPECS.md §11.2), "who can see what" at a glance; also as
# CSV (/access.csv): email, name, then per app its role and where it comes from. An app with the MCP channel (§25)
# has a column per channel; the CSV's MCP columns are named "<slug> mcp", "<slug> mcp source". A multiple-roles app (§23.2)
# has its roles in one cell ("Management; Support"), their sources ("Management: direct; Support: RO Dev") and a
# third column with the resolved permissions.
class Admin::AccessMatrixController < Admin::BaseController
  def show
    @apps = App.active.ordered.includes(:roles).to_a
    @columns = @apps.flat_map { |app| app.channels.map { [ app, _1 ] } }
    @roles = @columns.to_h { |app, channel| [ [ app.id, channel ], EffectiveRole.members_of(app, channel: channel).index_by { _1.user.id } ] }
    @users = User.active.ordered.to_a
    @users = @users.select { |user| @roles.values.any? { _1.key?(user.id) } } if params[:with_access] == "1"

    respond_to do |format|
      format.html
      format.csv do
        AuditEvent.record("access.exported", data: { users: @users.size, apps: @apps.map(&:slug) })
        send_data csv, type: "text/csv; charset=utf-8", filename: "access-matrix-#{Date.current.iso8601}.csv"
      end
    end
  end

  private

  def csv
    header = [ "email", "name" ] + @columns.flat_map do |app, channel|
      name = channel == "web" ? app.slug : "#{app.slug} #{channel}"
      [ name, "#{name} source" ] + (app.multiple_roles? ? [ "#{name} permissions" ] : [])
    end
    rows = @users.map do |user|
      [ user.email, user.name ] + @columns.flat_map do |app, channel|
        access = @roles[[ app.id, channel ]][user.id]
        if app.multiple_roles?
          [ access&.role_keys&.join("; "), access&.held&.map { "#{_1.key}: #{_1.sources.join(', ')}" }&.join("; "), access&.permissions&.join(" ") ]
        else
          [ access&.role_key, access && (access.direct? ? "direct" : access.source) ]
        end
      end
    end
    ([ header ] + rows).map { |row| CsvLine.call(row) }.join
  end
end
