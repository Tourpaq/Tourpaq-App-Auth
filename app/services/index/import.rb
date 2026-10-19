# Imports Tourpaq-App-WWW's production content into the index (SPECS.md §24.3) from the file its
# script/index_export.rb writes ("tourpaq-index-export", version 1):
#
#   report = Index::Import.call(File.read(path), apply: false, source: "tourpaq-index-export.json")
#   puts report        # every create, change and skip, the rows only here, and a summary per kind
#   report.applied?    # false for a dry run: everything ran inside a transaction that was rolled back
#
# Matching (natural keys, so running it again changes nothing): the site is the one row; categories become sections by
# slug; access levels and login methods by key; apps become entries by slug; an app's links by label (case does not
# matter); doc sections by key; docs by section and slug.
#
# Mapping: a category's audience "everyone" becomes layout cards, visible to all Tourpaq staff; "technical" becomes
# layout table, visible to the groups DK Tech and RO DevOps (a missing group is left out and reported, so such a
# section is seen by fewer people, never by more). An app whose URL's host is an active auth App's host is tied to that
# App (then only its users see it); an entry that is already tied is never untied by the import (no host matching, or
# the App disabled, would otherwise show it to all staff). A new row keeps the export's created_at and
# updated_at.
#
# Rules: a new row is created; an existing row that differs is brought in line (a change), except that a row changed
# in the auth app after the last APPLIED import is left as it is (a skip): what admins edited here stands. A row the
# auth app rejects (validation) is a skip with the reason. Nothing is ever deleted: rows here that are not in the export
# are listed ("only here") for an admin to look at.
#
# Everything runs in one transaction, audited per change (index.<kind>.created / updated, with imported: true) and as a
# whole (index.imported). A dry run runs the same code and rolls it all back, so its report is exactly what APPLY=1 does.
class Index::Import
  FORMAT = "tourpaq-index-export".freeze
  VERSION = 1
  TABLES = %w[sites categories access_levels login_methods apps links doc_sections docs].freeze
  TECHNICAL_GROUPS = [ "DK Tech", "RO DevOps" ].freeze

  class Refused < StandardError; end

  # action: create, change, skip, ok (unchanged), keep (only here)
  Line = Data.define(:action, :kind, :subject, :detail) do
    def to_s = format("%-7s %-12s %-36s %s", action, kind, subject, detail).rstrip
  end

  KINDS = %w[site section access_level login_method entry link doc_section doc].freeze

  Report = Data.define(:source, :exported_at, :applied, :lines, :previous_at) do
    def applied? = applied
    def count(action, kind = nil) = lines.count { _1.action == action && (kind.nil? || _1.kind == kind) }
    def changes = lines.select { %w[create change].include?(_1.action) }

    def to_s
      out = []
      out << "Index import#{" of #{source}" if source} (exported #{exported_at || 'at an unknown time'}): " +
             (applied ? "APPLIED" : "DRY RUN, nothing was changed")
      if previous_at
        out << "An import was already applied on #{previous_at.utc.iso8601}: rows changed in the auth app since then are " \
               "left as they are (listed as skips)."
      end
      out << ""
      shown = lines.reject { _1.action == "ok" }
      out.concat(shown.empty? ? [ "Nothing to create or change." ] : shown.map(&:to_s))
      out << ""
      out << "Summary:"
      KINDS.each do |kind|
        out << format("  %-13s %d created, %d changed, %d unchanged, %d skipped, %d only here", kind.tr("_", " ").pluralize,
                      count("create", kind), count("change", kind), count("ok", kind), count("skip", kind), count("keep", kind))
      end
      out << ""
      out << (applied ? "Applied." : "Nothing was changed. Run again with APPLY=1 to apply.")
      out.join("\n")
    end
  end

  def self.call(json, apply: false, source: nil) = new(json, source: source).call(apply: apply)

  def initialize(json, source: nil)
    @data = parse(json)
    @source = source
    @lines = []
  end

  def call(apply:)
    @previous_at = AuditEvent.where(action: "index.imported").maximum(:created_at)
    ActiveRecord::Base.transaction do
      import_site
      import_vocabulary("access_levels", Index::AccessLevel, "access_level")
      import_vocabulary("login_methods", Index::LoginMethod, "login_method")
      import_sections
      import_entries
      import_doc_sections
      import_docs
      AuditEvent.record("index.imported", actor: nil, data: {
        source: @source, exported_at: @data["exported_at"], applied: apply,
        created: @lines.count { _1.action == "create" }, changed: @lines.count { _1.action == "change" },
        skipped: @lines.count { _1.action == "skip" }
      }.compact)
      raise ActiveRecord::Rollback unless apply
    end
    Report.new(source: @source, exported_at: @data["exported_at"], applied: apply, lines: @lines, previous_at: @previous_at)
  end

  private

  def parse(json)
    data = JSON.parse(json.to_s)
    raise Refused, "not a JSON object" unless data.is_a?(Hash)
    unless data["format"] == FORMAT && data["version"] == VERSION
      raise Refused, "this is not a #{FORMAT} version #{VERSION} file (format #{data['format'].inspect}, version #{data['version'].inspect})"
    end
    missing = TABLES.reject { data[_1].is_a?(Array) && data[_1].all?(Hash) }
    raise Refused, "the file lacks the lists #{missing.join(', ')}" if missing.any?
    data
  rescue JSON::ParserError => e
    raise Refused, "not JSON (#{e.message.truncate(80)})"
  end

  def line(action, kind, subject, detail = "") = @lines << Line.new(action: action, kind: kind, subject: subject.to_s.truncate(36), detail: detail)

  def rows(table) = @data.fetch(table)
  def by_id(table) = (@by_id ||= {})[table] ||= rows(table).index_by { _1["id"] }
  def time(value) = value.present? ? Time.iso8601(value.to_s) : nil
  def timestamps(row) = { created_at: time(row["created_at"]), updated_at: time(row["updated_at"]) }.compact

  # Creates or brings in line one record. attrs: the columns as the export wants them; groups: Group records (sections).
  # Returns the record (nil when it could not be created).
  def upsert(kind, subject, record, attrs, row:, groups: nil, &build)
    if record.nil?
      record = yield_new(attrs, row, groups, &build)
      if record.save
        audit("#{kind}.created", record, { subject: subject })
        links = record.respond_to?(:links) ? record.links.size : 0
        line("create", kind, subject, links.positive? ? "with #{links} #{'link'.pluralize(links)}" : "")
        return record
      end
      line("skip", kind, subject, "refused: #{record.errors.full_messages.to_sentence}")
      return nil
    end

    diff = attrs.reject { |key, value| normalised(record.public_send(key)) == normalised(record.class.normalize_value_for(key, value)) }
    diff["groups"] = groups.map(&:name).sort if groups && record.groups.map(&:name).sort != groups.map(&:name).sort
    return record.tap { line("ok", kind, subject) } if diff.empty?
    if @previous_at && record.updated_at && record.updated_at > @previous_at
      line("skip", kind, subject, "changed in the auth app since the last import (#{diff.keys.join(', ')} differ)")
      return record
    end
    saved = record.class.transaction(requires_new: true) do
      record.groups = groups if groups
      record.update(attrs) || raise(ActiveRecord::Rollback)
    end
    if saved
      audit("#{kind}.updated", record, { subject: subject, changes: diff.keys })
      line("change", kind, subject, diff.keys.join(", "))
    else
      record.restore_attributes
      line("skip", kind, subject, "refused: #{record.errors.full_messages.to_sentence}")
    end
    record
  end

  def yield_new(attrs, row, groups)
    record = yield
    record.assign_attributes(attrs.merge(timestamps(row)))
    record.groups = groups if groups
    record
  end

  def normalised(value) = value.is_a?(String) ? value.presence : value

  def audit(action, record, data)
    AuditEvent.record("index.#{action}", subject: record, actor: nil, data: data.merge(imported: true))
  end

  # Rows of the auth app that the export does not have: left as they are, listed.
  def only_here(kind, scope, keys, &label)
    scope.where.not(id: nil).find_each do |record|
      key = label.call(record)
      line("keep", kind, key, "not in the export: left as it is") unless keys.include?(key)
    end
  end

  def import_site
    row = rows("sites").first or return
    attrs = { title: row["title"], brand: row["brand"], tagline: row["tagline"], footer: row["footer"] }
    upsert("site", "site", Index::Site.first, attrs, row: row) { Index::Site.new }
  end

  def import_vocabulary(table, model, kind)
    keys = rows(table).map do |row|
      key = Index::Toned.normalise(row["key"])
      attrs = { label: row["label"], tone: row["tone"], position: row["position"] }
      upsert(kind, key, model.find_by(key: key), attrs, row: row) { model.new(key: key) }
      key
    end
    only_here(kind, model, keys, &:key)
  end

  def import_sections
    technical = TECHNICAL_GROUPS.filter_map { |name| Group.find_by(name: name) }
    missing = TECHNICAL_GROUPS - technical.map(&:name)
    slugs = rows("categories").map do |row|
      table = row["audience"] == "technical"
      attrs = { name: row["name"], description: row["description"], position: row["position"], layout: table ? "table" : "cards",
                visibility: table ? "groups" : "everyone" }
      if table && missing.any?
        line("skip", "section", row["slug"], "the group#{'s' if missing.size > 1} #{missing.join(', ')} not found: left out of its visibility")
      end
      upsert("section", row["slug"], Index::Section.find_by(slug: row["slug"]), attrs, row: row, groups: table ? technical : []) do
        Index::Section.new(slug: row["slug"])
      end
      row["slug"]
    end
    only_here("section", Index::Section, slugs, &:slug)
  end

  def import_entries
    app_hosts = App.active.where.not(url: [ nil, "" ]).to_a.index_by { host(_1.url) }
    links_by_app = rows("links").group_by { _1["app_id"] }
    slugs = rows("apps").map do |row|
      attrs = {
        name: row["name"], description: row["description"], url: row["url"], address: row["address"],
        status: row["status"], owner: row["owner"], repo: row["repo"], icon: row["icon"], position: row["position"], body: row["body"],
        section_id: Index::Section.find_by(slug: by_id("categories")[row["category_id"]]&.dig("slug"))&.id,
        access_level_id: Index::AccessLevel.find_by(key: Index::Toned.normalise(by_id("access_levels")[row["access_level_id"]]&.dig("key")))&.id,
        login_method_id: Index::LoginMethod.find_by(key: Index::Toned.normalise(by_id("login_methods")[row["login_method_id"]]&.dig("key")))&.id,
        app_id: app_hosts[host(row["url"])]&.id
      }
      links = (links_by_app[row["id"]] || []).sort_by { [ _1["position"].to_i, _1["id"].to_i ] }
      existing = Index::Entry.find_by(slug: row["slug"])
      # Never untie: an entry tied to an App is seen by that App's users only, and its own visibility is not used (it
      # is "everyone"), so clearing the tie would show it to all staff. Only an admin unties.
      attrs.delete(:app_id) if attrs[:app_id].nil? && existing&.app_id
      entry = upsert("entry", row["slug"], existing, attrs, row: row) do
        Index::Entry.new(slug: row["slug"]).tap do |fresh|
          links.each { |l| fresh.links.build(label: l["label"], url: l["url"], note: l["note"], position: l["position"], **timestamps(l)) }
        end
      end
      import_links(entry, row["slug"], links) if existing && entry
      row["slug"]
    end
    only_here("entry", Index::Entry, slugs, &:slug)
  end

  # The links of an entry that already existed (a new entry got them at its creation).
  def import_links(entry, entry_slug, links)
    links.each do |row|
      subject = "#{entry_slug}: #{row['label']}"
      existing = entry.links.detect { _1.label.to_s.casecmp?(row["label"].to_s.strip) }
      attrs = { label: row["label"], url: row["url"], note: row["note"], position: row["position"] }
      upsert("link", subject, existing, attrs, row: row) { entry.links.build }
    end
    labels = links.map { _1["label"].to_s.strip.downcase }
    entry.links.reload.each do |link|
      line("keep", "link", "#{entry_slug}: #{link.label}", "not in the export: left as it is") unless labels.include?(link.label.to_s.downcase)
    end
  end

  def import_doc_sections
    keys = rows("doc_sections").map do |row|
      key = Index::Sluggable.slugify(row["key"])
      upsert("doc_section", key, Index::DocSection.find_by(key: key), { title: row["title"], position: row["position"] }, row: row) do
        Index::DocSection.new(key: key)
      end
      key
    end
    only_here("doc_section", Index::DocSection, keys, &:key)
  end

  def import_docs
    paths = rows("docs").map do |row|
      section_key = by_id("doc_sections")[row["doc_section_id"]]&.dig("key")
      section = section_key && Index::DocSection.find_by(key: Index::Sluggable.slugify(section_key))
      path = section_key ? "#{section_key}/#{row['slug']}" : row["slug"]
      attrs = { title: row["title"], summary: row["summary"], body: row["body"], position: row["position"] }
      upsert("doc", path, Index::Doc.find_by(doc_section: section, slug: row["slug"]), attrs, row: row) do
        Index::Doc.new(doc_section: section, slug: row["slug"])
      end
      path
    end
    only_here("doc", Index::Doc.includes(:doc_section), paths) { |doc| doc.doc_section ? "#{doc.doc_section.key}/#{doc.slug}" : doc.slug }
  end

  def host(url)
    URI.parse(url.to_s).host&.downcase
  rescue URI::InvalidURIError
    nil
  end
end
