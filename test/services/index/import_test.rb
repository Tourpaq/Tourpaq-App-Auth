require "test_helper"

# auth:import_index (SPECS.md §24.3): WWW's tourpaq-index-export v1 into the index. Dry run by default, idempotent,
# audited, every create/change/skip reported, other formats refused.
class Index::ImportTest < ActiveSupport::TestCase
  FILE = Rails.root.join("test/fixtures/files/tourpaq-index-export.json")

  setup do
    @json = FILE.read
    @dashboard = App.create!(slug: "dashboard", name: "Dashboard", url: "https://home.app.journeybooking.eu", multiple_roles: true)
  end

  def empty_index!
    [ Index::Link, Index::EntryGroup, Index::Entry, Index::Doc, Index::DocSection, Index::SectionGroup, Index::Section,
      Index::AccessLevel, Index::LoginMethod, Index::Site ].each(&:delete_all)
  end

  def import(json = @json, apply: true) = Index::Import.call(json, apply: apply, source: "export.json")

  def export_with
    data = JSON.parse(@json)
    yield data
    JSON.generate(data)
  end

  test "a dry run reports every create and changes nothing" do
    empty_index!
    report = import(apply: false)
    assert_not report.applied?
    assert_equal 0, Index::Entry.count
    assert_equal 0, AuditEvent.where("action LIKE 'index.%'").count
    text = report.to_s
    assert_match "DRY RUN, nothing was changed", text
    assert_match(/create\s+entry\s+salesview/, text)
    assert_match(/create\s+section\s+databases/, text)
    assert_match(/entries\s+5 created, 0 changed/, text)
    assert_match "Run again with APPLY=1", text
  end

  test "applied into an empty index: sections, entries with links, vocabularies, docs and the site" do
    empty_index!
    report = import
    assert report.applied?
    assert_equal [ "Tourpaq DK Home", "TP DK Home" ], [ Index::Site.current.title, Index::Site.current.brand ]
    assert_equal %w[apps databases devops], Index::Section.order(:slug).pluck(:slug)
    assert_equal %w[azure-vpn netbird], Index::AccessLevel.order(:key).pluck(:key)
    assert_equal 5, Index::Entry.count

    apps = Index::Section.find_by!(slug: "apps")
    assert_equal [ "cards", "everyone", [] ], [ apps.layout, apps.visibility, apps.groups.to_a ]
    databases = Index::Section.find_by!(slug: "databases")
    assert_equal [ "table", "groups", [ "DK Tech", "RO DevOps" ] ], [ databases.layout, databases.visibility, databases.groups.map(&:name).sort ]

    trace = Index::Entry.find_by!(slug: "trace")
    assert_equal [ "devops", "azure-vpn", "limited" ], [ trace.section.slug, trace.access_level.key, trace.login_method.key ]
    assert_equal [ "Booking Engine - Slow requests the last hour", "Errors" ], trace.links.map(&:label)
    assert_equal "last 24h", trace.links.last.note
    assert_nil Index::Entry.find_by!(slug: "backup-control-plane").section
    assert_equal "## Connecting\n\nRead-only login in 1Password.", Index::Entry.find_by!(slug: "ms-sql-master-x").body

    home = Index::Entry.find_by!(slug: "home")
    assert_equal @dashboard, home.app, "tied by its URL's host to the Dashboard's app"
    assert_nil Index::Entry.find_by!(slug: "salesview").app
    assert_equal Time.utc(2026, 10, 11, 9, 30), Index::Entry.find_by!(slug: "salesview").updated_at, "the export's times are kept"

    assert_equal [ "deployment/deploying-a-new-app", "faq" ], Index::Doc.includes(:doc_section).map { _1.path.delete_prefix("/docs/") }.sort

    run = AuditEvent.where(action: "index.imported").last
    assert_equal [ true, 0, 16 ], [ run.data["applied"], run.data["changed"], run.data["created"] ]
    created = AuditEvent.where(action: "index.entry.created").order(:id).last
    assert created.data["imported"]
    assert_nil created.actor
  end

  test "running it again changes nothing" do
    empty_index!
    import
    counts = [ Index::Entry, Index::Link, Index::Section, Index::SectionGroup, Index::Doc ].map(&:count)
    report = import
    assert_equal counts, [ Index::Entry, Index::Link, Index::Section, Index::SectionGroup, Index::Doc ].map(&:count)
    assert_empty report.changes
    assert_match "Nothing to create or change.", report.to_s
    assert_match "An import was already applied", report.to_s
    assert_match(/entries\s+0 created, 0 changed, 5 unchanged/, report.to_s)
  end

  test "existing rows are brought in line; rows only here are listed and left" do
    report = import
    salesview = index_entries(:salesview).reload
    assert_equal "Salesview for viewing existing and creating new bookings", salesview.description
    assert_equal "📈", salesview.icon
    assert_match(/change\s+entry\s+salesview\s+.*description/, report.to_s)
    assert Index::Entry.exists?(slug: "ms-sql-master-bravo"), "nothing is ever deleted"
    assert_match(/keep\s+entry\s+ms-sql-master-bravo\s+not in the export/, report.to_s)
  end

  test "what an admin changed after an applied import stands at the next one" do
    empty_index!
    import
    travel 1.minute do
      Index::Entry.find_by!(slug: "salesview").update!(description: "Bookings, edited here.")
      Index::Section.find_by!(slug: "databases").update!(groups: [ groups(:dk_tech) ])
    end
    changed = export_with { |data| data["apps"].first["owner"] = "Samantha" }
    report = travel(2.minutes) { import(changed) }
    assert_equal "Bookings, edited here.", Index::Entry.find_by!(slug: "salesview").description
    assert_match(/skip\s+entry\s+salesview\s+changed in the auth app since the last import/, report.to_s)
    assert_equal [ "DK Tech" ], Index::Section.find_by!(slug: "databases").groups.map(&:name)
  end

  test "an entry tied to an app stays tied when no app's host matches its URL, never widening the visibility" do
    salesview = index_entries(:salesview)
    salesview.update!(app: apps(:kpi)) # tied by an admin (or the seeds), not by an import
    assert_equal "everyone", salesview.reload.visibility
    import
    assert_equal apps(:kpi), salesview.reload.app, "salesview.app.journeybooking.eu is no app's host: the tie stays"

    empty_index!
    import
    home = Index::Entry.find_by!(slug: "home")
    assert_equal @dashboard, home.app
    @dashboard.update!(url: "https://dashboard.app.journeybooking.eu")
    report = travel(1.minute) { import }
    assert_equal @dashboard, home.reload.app, "the App's host changed: the entry stays tied"
    assert_match(/entries\s+0 created, 0 changed, 5 unchanged/, report.to_s)

    @dashboard.update!(url: "https://home.app.journeybooking.eu", disabled_at: Time.current)
    travel(2.minutes) { import }
    assert_equal @dashboard, home.reload.app, "the App is disabled: the entry stays tied (and hidden, as its App)"
  end

  test "a missing technical group is reported and left out, never widening the visibility" do
    empty_index!
    groups(:ro_devops).destroy!
    report = import
    assert_equal [ "DK Tech" ], Index::Section.find_by!(slug: "databases").groups.map(&:name)
    assert_match(/skip\s+section\s+databases\s+the group RO DevOps not found/, report.to_s)
  end

  test "a row the index refuses is a skip with the reason; the rest is imported" do
    empty_index!
    bad = export_with { |data| data["apps"].first["url"] = "javascript:alert(1)" }
    report = import(bad)
    assert_nil Index::Entry.find_by(slug: "salesview")
    assert_equal 4, Index::Entry.count
    assert_match(/skip\s+entry\s+salesview\s+refused: Url must start with https/, report.to_s)
  end

  test "other formats are refused" do
    assert_raises(Index::Import::Refused) { import("not json") }
    assert_raises(Index::Import::Refused) { import("[]") }
    assert_raises(Index::Import::Refused) { import(export_with { |d| d["format"] = "tourpaq-dashboard-export" }) }
    assert_raises(Index::Import::Refused) { import(export_with { |d| d["version"] = 2 }) }
    error = assert_raises(Index::Import::Refused) { import(export_with { |d| d.delete("docs") }) }
    assert_match "docs", error.message
    assert_equal 0, AuditEvent.where(action: "index.imported").count
  end

  # test/fixtures/files/www-head-export.json was written by Tourpaq-App-WWW's script/index_export.rb, run on WWW's HEAD
  # (the deployed version) against a database seeded with WWW's own seed content: the round trip of SPECS.md §24.3.
  test "the round trip: an export written by WWW's script imports into an empty index, and again changes nothing" do
    empty_index!
    json = Rails.root.join("test/fixtures/files/www-head-export.json").read
    data = JSON.parse(json)
    assert_equal [ "tourpaq-index-export", 1, "Tourpaq-App-WWW" ], [ data["format"], data["version"], data.dig("source", "app") ]

    report = import(json)
    assert_equal 0, report.count("skip"), report.to_s
    assert_equal data["counts"].values_at("apps", "categories", "docs", "doc_sections", "access_levels", "login_methods"),
                 [ Index::Entry.count, Index::Section.count, Index::Doc.count, Index::DocSection.count, Index::AccessLevel.count, Index::LoginMethod.count ]
    assert_equal data["counts"]["links"], Index::Link.count
    assert_equal %w[Apps Reporting], Index::Section.where(visibility: "everyone").ordered.pluck(:name)
    assert_equal @dashboard, Index::Entry.find_by!(slug: "home").app
    Index::Entry.includes(:links).find_each { |entry| assert entry.valid?, "#{entry.slug}: #{entry.errors.full_messages}" }

    again = import(json)
    assert_empty again.changes
    assert_equal 0, again.count("skip")
  end
end
