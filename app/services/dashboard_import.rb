# Imports the Dashboard's users, groups and memberships (SPECS.md §23.5 step 2) from the file its
# `bin/rails auth:export` writes ("tourpaq-dashboard-export", version 1):
#
#   report = DashboardImport.call(File.read(path), apply: false, source: "dashboard-export.json")
#   puts report        # every create, change and skip, the check, and the tokens whose owners to tell
#   report.applied?    # false for a dry run: everything ran inside a transaction that was rolled back
#   DashboardImport.call(json, apply: true, force: true)   # apply again after an earlier applied run (FORCE=1)
#
# Rules:
# - Users with an entra_oid: matched by (oid, ENTRA_TENANT_ID); else an unbound user with the email is bound
#   (once, as at a first sign-in); else created bound. An email that belongs to another Entra account is skipped.
# - Users without an oid (from YouTrack, never signed in): created pre-created only when they are active and hold
#   a membership; an existing user with the email is used; otherwise skipped.
# - Inactive users get no grants, and are not disabled here: the Dashboard's "inactive" was about the Dashboard.
# - Groups become roles of the app "dashboard" with the same name, description and permissions; the
#   Administrators group (the system group) becomes "Administrators" with "*". An existing role of that name is
#   brought in line (a change).
# - Memberships become direct grants (GrantChange, audited with before/after). A user whose direct grant in the
#   auth app is "no access" keeps it: those memberships are skipped.
# - Nothing is removed, so running it again changes nothing.
# - Once an import has been APPLIED, applying one again is refused unless forced (FORCE=1): the export is a snapshot
#   of the cutover, and access has been managed here since. Even forced (and in a dry run after it), what admins
#   changed after the last applied run stands: a role added, edited or removed since is left as it is, and a
#   membership whose grant was removed or replaced since is not granted again; each is listed as a skip.
# - A role change goes through the per-app last-administrator guard (AppAdminGuard), as in the role editor; a
#   refused change is a skip.
#
# Then it checks what the auth app now reports against the export's resolved permissions: an inactive user must
# have no access, an active user exactly the export's permissions ("*" equal only to "*"). The Dashboard's own
# auth:verify_import does the same against the members API after the cutover.
#
# Everything runs in one transaction, audited per change (user.created / user.bound / user.precreated /
# app.role_added / app.role_changed / grant.created) and as a whole (import.dashboard). A dry run rolls it all back.
class DashboardImport
  FORMAT = "tourpaq-dashboard-export".freeze
  VERSION = 1
  APP_SLUG = "dashboard".freeze
  ADMIN_GROUP = "Administrators".freeze

  class Refused < StandardError; end

  # action: create, change, skip, ok, check (a difference), notify (a token owner to tell)
  Line = Data.define(:action, :kind, :subject, :detail) do
    def to_s = format("%-7s %-6s %-36s %s", action, kind, subject, detail).rstrip
  end

  Report = Data.define(:source, :exported_at, :applied, :lines, :previous_at) do
    def initialize(previous_at: nil, **fields) = super
    def applied? = applied
    def count(action, kind = nil) = lines.count { _1.action == action && (kind.nil? || _1.kind == kind) }
    def changes = lines.select { %w[create change].include?(_1.action) }
    def differences = lines.select { _1.action == "check" }

    def to_s
      out = []
      out << "Dashboard import#{" of #{source}" if source} (exported #{exported_at || 'at an unknown time'}): " +
             (applied ? "APPLIED" : "DRY RUN, nothing was changed")
      if previous_at
        out << "An import was already applied on #{previous_at.utc.iso8601}: roles and grants changed in the auth app " \
               "since then are left as they are (listed as skips)."
      end
      out << ""
      shown = lines.reject { %w[ok check notify].include?(_1.action) }
      out.concat(shown.empty? ? [ "Nothing to create or change." ] : shown.map(&:to_s))
      out << ""
      out << "Summary:"
      %w[role user grant].each do |kind|
        out << format("  %-6s %d created, %d changed, %d unchanged, %d skipped", "#{kind}s", count("create", kind), count("change", kind),
                      count("ok", kind), count("skip", kind))
      end
      out << ""
      if differences.empty?
        out << "Check: every user's permissions match the export."
      else
        out << "Check: #{differences.size} #{differences.size == 1 ? 'difference' : 'differences'}:"
        out.concat(differences.map { "  #{_1}" })
      end
      tokens = lines.select { _1.action == "notify" }
      if tokens.any?
        out << ""
        out << "Dashboard tokens stop at the cutover; tell their owners to create tpa_dashboard_ tokens (SPECS.md §23.5 step 5):"
        out.concat(tokens.map { "  #{_1.subject}: #{_1.detail}" })
      end
      out << "" << "Run again with #{'FORCE=1 ' if previous_at}APPLY=1 to apply." unless applied
      out.join("\n")
    end
  end

  def self.call(json, apply: false, source: nil, force: false) = new(json, source: source).call(apply: apply, force: force)

  def initialize(json, source: nil)
    @source = source
    @data = parse(json)
    @lines = []
  end

  def call(apply:, force: false)
    @app = App.find_by(slug: APP_SLUG) or raise Refused, "There is no app \"#{APP_SLUG}\": run the seeds first (bin/rails db:seed)."
    raise Refused, "The app \"#{APP_SLUG}\" must have multiple roles (SPECS.md §23.2)." unless @app.multiple_roles?
    @previous = previous_import
    if apply && @previous && !force
      raise Refused, "The Dashboard import was already applied on #{@previous.created_at.utc.iso8601} " \
                     "(#{@previous.data['source'] || 'unknown file'}, exported #{@previous.data['exported_at'] || 'at an unknown time'}). " \
                     "Access has been managed in the auth app since, and applying an export again could bring back access " \
                     "that was taken away. Run it without APPLY=1 to see what it would do, and with FORCE=1 APPLY=1 to " \
                     "apply it anyway (roles and grants changed here since then are left as they are)."
    end
    load_later_changes
    @tenant = Rails.configuration.x.auth.entra_tenant_id
    if @tenant.blank? && @data["users"].any? { _1["entra_oid"].present? }
      raise Refused, "ENTRA_TENANT_ID is not set: imported users are bound to that tenant."
    end

    ApplicationRecord.transaction do
      @roles = import_roles
      @users = import_users
      import_memberships
      check
      list_tokens
      AuditEvent.record("import.dashboard", subject: @app, actor: nil,
                        data: { source: @source, exported_at: @data["exported_at"], applied: apply,
                                digest: Digest::SHA256.hexdigest(@json_text).first(16),
                                created: tally("create"), changed: tally("change"), skipped: tally("skip"),
                                differences: @lines.count { _1.action == "check" }, tokens: @lines.count { _1.action == "notify" } }
                                .merge(@previous ? { after_import_of: @previous.created_at.utc.iso8601, forced: force } : {}))
      raise ActiveRecord::Rollback unless apply
    end
    Report.new(source: @source, exported_at: @data["exported_at"], applied: apply, lines: @lines, previous_at: @previous&.created_at)
  end

  private

  def parse(json)
    @json_text = json.to_s
    data = JSON.parse(@json_text)
    raise Refused, "The file is not a JSON object." unless data.is_a?(Hash)
    unless data["format"] == FORMAT && data["version"] == VERSION
      raise Refused, "This is not a Dashboard export this import understands (format #{data['format'].inspect}, version " \
                     "#{data['version'].inspect}; expected #{FORMAT.inspect}, version #{VERSION})."
    end
    %w[users groups memberships].each do |list|
      raise Refused, "The export has no #{list} list." unless data[list].is_a?(Array) && data[list].all?(Hash)
    end
    %w[resolved_permissions api_tokens].each do |list|
      data[list] = [] if data[list].nil?
      raise Refused, "The export's #{list} is not a list." unless data[list].is_a?(Array) && data[list].all?(Hash)
    end
    data
  rescue JSON::ParserError
    raise Refused, "The file is not JSON."
  end

  def line(action, kind, subject, detail = nil) = @lines << Line.new(action: action, kind: kind, subject: subject.to_s, detail: detail.to_s)

  def tally(action) = @lines.select { _1.action == action }.group_by(&:kind).transform_values(&:size)

  # --- what admins changed after the last applied import ---------------------------------------------

  def previous_import
    AuditEvent.where(action: "import.dashboard", app: @app).order(:id).reverse_each.find { _1.data["applied"] == true }
  end

  # Role keys (downcased) added, edited or removed in the admin UI after the last applied import, and the
  # [user id, role key] pairs whose direct grant was removed or replaced since. Empty before the first import.
  def load_later_changes
    @later_roles = {}
    @later_grants = Set.new
    return unless @previous
    since = AuditEvent.where(app: @app).where("audit_events.id > ?", @previous.id).order(:id)
    since.where(action: %w[app.role_added app.role_changed app.role_removed]).each do |event|
      next if event.data["via"] == "dashboard_import"
      @later_roles[event.data["key"].to_s.downcase] = event.action.delete_prefix("app.role_")
    end
    since.where(action: %w[grant.removed grant.created], subject_type: "User").each do |event|
      keys = event.action == "grant.removed" ? [ event.data["role_before"] ] : Array(event.data["replaced"])
      keys.compact.each { @later_grants << [ event.subject_id, _1.to_s.downcase ] }
    end
  end

  def since_previous = "since the import of #{@previous.created_at.utc.to_date.iso8601}"

  # --- groups → roles ----------------------------------------------------------------------------

  def import_roles
    @data["groups"].each_with_object({}) do |group, roles|
      name = group["name"].to_s.strip.squeeze(" ")
      next line("skip", "role", "(group #{group['id']})", "no name") if name.empty?
      admin = name == ADMIN_GROUP || group["system"] == true
      permissions = admin ? [ AppRole::WILDCARD ] : AppRole.normalize_permissions(group["permissions"])
      description = group["description"].to_s.strip.presence

      role = @app.roles.reload.detect { _1.key.casecmp?(name) }
      if (how = @later_roles[name.downcase])
        line("skip", "role", name, "#{how} in the auth app #{since_previous}: left as it is")
        next roles[group["id"]] = role if role
        next
      end
      if role.nil?
        role = @app.roles.build(key: name, description: description, permissions: permissions,
                                position: (@app.roles.maximum(:position) || 0) + 1)
        unless role.save
          @app.roles.reset
          next line("skip", "role", name, "invalid: #{role.errors.full_messages.to_sentence}")
        end
        AuditEvent.record("app.role_added", subject: @app, actor: nil,
                          data: { key: role.key, description: description, permissions: permissions, via: "dashboard_import" })
        line("create", "role", name, permissions == [ AppRole::WILDCARD ] ? "everything (*)" : "#{permissions.size} #{permissions.size == 1 ? "permission" : "permissions"}")
      elsif role.permissions != permissions || role.description != description
        before = role.permissions
        begin
          saved = AppAdminGuard.protect(@app) { role.update(description: description, permissions: permissions) }
        rescue AppAdminGuard::LastAdmin => e
          role.restore_attributes
          next line("skip", "role", name, "refused: #{e.message}")
        end
        next line("skip", "role", name, "invalid: #{role.errors.full_messages.to_sentence}") unless saved
        AuditEvent.record("app.role_changed", subject: @app, actor: nil,
                          data: { key: role.key, description: description, permissions_added: permissions - before,
                                  permissions_removed: before - permissions, via: "dashboard_import" })
        line("change", "role", role.key, [ ("+#{(permissions - before).join(' +')}" if (permissions - before).any?),
                                           ("-#{(before - permissions).join(' -')}" if (before - permissions).any?),
                                           ("description" if role.saved_change_to_description?) ].compact.join(" "))
      else
        line("ok", "role", role.key)
      end
      roles[group["id"]] = role
    end
  end

  # --- users -------------------------------------------------------------------------------------

  def import_users
    member_ids = @data["memberships"].select { @roles.key?(_1["group_id"]) }.map { _1["user_id"] }.to_set
    seen = Set.new
    @data["users"].each_with_object({}) do |entry, users|
      email = entry["email"].to_s.strip.downcase
      next line("skip", "user", email.presence || "(user #{entry['id']})", "no valid email") unless email.match?(URI::MailTo::EMAIL_REGEXP)
      next line("skip", "user", email, "listed twice in the export") unless seen.add?(email)
      active = entry["active"] != false
      oid = entry["entra_oid"].to_s.strip.presence
      user = oid ? bound_user(entry, email, oid, active) : unbound_user(entry, email, active, member_ids.include?(entry["id"]))
      users[entry["id"]] = user if user
    end
  end

  def bound_user(entry, email, oid, active)
    note = active ? nil : "inactive in the Dashboard: no grants, not disabled here"
    if (user = User.find_by(entra_oid: oid, entra_tid: @tenant))
      line("ok", "user", email, [ "matched by oid", note ].compact.join("; "))
      return user
    end
    if (user = User.unbound.find_by(email: email))
      user.update!(entra_oid: oid, entra_tid: @tenant)
      AuditEvent.record("user.bound", subject: user, actor: nil, data: { email: email, via: "dashboard_import" })
      line("change", "user", email, [ "bound to its Entra account by email", note ].compact.join("; "))
      return user
    end
    if User.exists?(email: email)
      line("skip", "user", email, "the email belongs to another Entra account in the auth app: sort it out by hand")
      return nil
    end
    user = User.create!(email: email, name: entry["name"].to_s.strip.presence, entra_oid: oid, entra_tid: @tenant,
                        skip_pending_notification: true)
    AuditEvent.record("user.created", subject: user, actor: nil, data: { via: "dashboard_import", email: email })
    line("create", "user", email, [ "created bound", note ].compact.join("; "))
    user
  end

  def unbound_user(entry, email, active, member)
    return line("skip", "user", email, "inactive and never signed in") && nil unless active
    return line("skip", "user", email, "never signed in and in no group") && nil unless member
    if (user = User.find_by_email(email))
      line("ok", "user", email, "matched by email")
      return user
    end
    user = User.create!(email: email, name: entry["name"].to_s.strip.presence)
    AuditEvent.record("user.precreated", subject: user, actor: nil, data: { email: email, via: "dashboard_import" })
    line("create", "user", email, "created pre-created (bound at the first sign-in)")
    user
  end

  # --- memberships → direct grants ---------------------------------------------------------------

  def import_memberships
    active_ids = @data["users"].reject { _1["active"] == false }.map { _1["id"] }.to_set
    emails = @data["users"].to_h { [ _1["id"], _1["email"].to_s.strip.downcase.presence ] }
    groups = @data["groups"].to_h { [ _1["id"], _1["name"] ] }
    @data["memberships"].each do |membership|
      role = @roles[membership["group_id"]]
      user = @users[membership["user_id"]]
      label = "#{user&.email || emails[membership['user_id']] || "user #{membership['user_id']}"} → " \
              "#{role&.key || groups[membership['group_id']] || "group #{membership['group_id']}"}"
      next line("skip", "grant", label, "the group was not imported") unless role
      next line("skip", "grant", label, "the user was not imported") unless user
      next line("skip", "grant", label, "inactive in the Dashboard") unless active_ids.include?(membership["user_id"])

      existing = Grant.where(app: @app, subject: user).to_a
      next line("ok", "grant", label) if existing.any? { _1.app_role_id == role.id }
      if @later_grants.include?([ user.id, role.key.downcase ])
        next line("skip", "grant", label, "removed in the auth app #{since_previous}: not granted again")
      end
      next line("skip", "grant", label, "the user has no access to #{@app.name} in the auth app (a direct grant)") if existing.any?(&:no_access?)
      grant = GrantChange.set(app: @app, subject: user, role: role)
      next line("skip", "grant", label, grant.errors.full_messages.to_sentence) if grant.errors.any?
      line("create", "grant", label, "direct")
    end
  end

  # --- the check (SPECS.md §23.5 step 4, as far as the auth app can tell) ---------------------------

  def check
    by_email = @users.values.index_by(&:email)
    @data["resolved_permissions"].each do |entry|
      email = entry["email"].to_s.strip.downcase
      user = @users[entry["user_id"]] || by_email[email]
      result = user ? EffectiveRole.for(user.reload, @app) : nil
      actual = result&.access? ? result.permissions : nil
      if entry["active"] == false
        line("check", "user", email, "inactive in the Dashboard but has access: #{actual.join(' ')}") if actual
        next
      end
      expected = AppRole.normalize_permissions(entry["permissions"])
      next if expected == (actual || [])
      line("check", "user", email, "expected #{expected.join(' ').presence || 'none'}; the auth app gives #{actual ? actual.join(' ').presence || 'none' : 'no access'}")
    end
  end

  def list_tokens
    @data["api_tokens"].each do |token|
      line("notify", "token", token["user_email"], "\"#{token['name']}\" (capability #{token['capability']}, " \
                                                    "last used #{token['last_used_at'] || 'never'}, expires #{token['expires_at'] || 'never'})")
    end
  end
end
