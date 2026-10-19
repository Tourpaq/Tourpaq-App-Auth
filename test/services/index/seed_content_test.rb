require "test_helper"

# The index's seed content (db/seeds/index, from WWW's db/seeds/content), loaded only into an empty index.
class Index::SeedContentTest < ActiveSupport::TestCase
  ROOT = Rails.root.join("db/seeds/index")

  setup do
    [ Index::Link, Index::EntryGroup, Index::Entry, Index::Doc, Index::DocSection, Index::SectionGroup, Index::Section,
      Index::AccessLevel, Index::LoginMethod, Index::Site ].each(&:delete_all)
    @dashboard = App.create!(slug: "home", name: "Dashboard", url: "https://home.app.journeybooking.eu", multiple_roles: true)
    @azure = App.new(slug: "azure-cost", name: "Azure Cost", url: "https://azurecost.app.journeybooking.eu")
    @azure.roles.build(key: "viewer", position: 1)
    @azure.save!
  end

  def seed = Index::SeedContent.load_if_empty(ROOT, log: StringIO.new)

  test "loads the seed content the index started from" do
    assert seed
    assert_equal "Tourpaq DK Home", Index::Site.current.title
    assert_equal %w[Apps Reporting Infrastructure DevOps Databases Integrations], Index::Section.ordered.pluck(:name)

    databases = Index::Section.find_by!(name: "Databases")
    assert databases.table?
    assert_equal [ "DK Tech", "RO DevOps" ], databases.groups.map(&:name).sort, "WWW's technical: DK Tech and RO DevOps"
    apps = Index::Section.find_by!(name: "Apps")
    assert_equal [ "cards", "everyone" ], [ apps.layout, apps.visibility ]

    trace = Index::Entry.find_by!(slug: "trace")
    assert_equal [ "Booking Engine - Slow requests the last hour" ], trace.links.map(&:label)
    assert_equal "azure-vpn", trace.access_level.key

    sql = Index::Entry.find_by!(name: "MS SQL Master - X")
    assert_equal "sql-p-we-01.tourpaq.com", sql.address
    assert_nil sql.url
    assert_equal "netbird-hetzner", sql.access_level.key
    assert_equal "Source code, merge requests and CI pipelines.", Index::Entry.find_by!(name: "GitLab").description
    assert_equal "index.seeded", AuditEvent.last.action
  end

  test "Tourpaq Home (formerly the Dashboard) at home.app, tied to its app; Azure Cost is tied too; no other card points at home.app" do
    seed
    dashboard = Index::Entry.find_by!(slug: "home")
    assert_equal [ "Tourpaq Home", "https://home.app.journeybooking.eu", "sso", @dashboard ],
                 [ dashboard.name, dashboard.url, dashboard.login_method&.key, dashboard.app ]
    assert_equal [ dashboard ], Index::Entry.where("url LIKE ?", "%//home.app.journeybooking.eu%").to_a
    assert_equal @azure, Index::Entry.find_by!(slug: "azure-cost-overview").app
    assert_equal [ dashboard ], Index::Entry.where("name LIKE ?", "%Tourpaq Home%").to_a, "one Home card, not the old one next to it"
  end

  test "a NetBird resource already on a card adds its address instead of a duplicate" do
    seed
    assert_nil Index::Entry.find_by(name: "Grafana - X")
    assert_equal "grafana.tourpaq.com", Index::Entry.find_by!(slug: "grafana-prod").address
    assert_equal 1, Index::Entry.where("url LIKE ?", "%//logs-tools.tourpaq.com%").count
  end

  test "relative .md links between docs become site paths" do
    seed
    body = Index::Doc.find_by!(slug: "deploying-a-new-app").body
    assert_includes body, "](/docs/getting-started/adding-an-app)"
    assert_not_includes body, ".md)"
  end

  test "only into an empty index: a second run changes nothing" do
    seed
    Index::Entry.find_by!(slug: "home").update!(name: "Dashboard")
    counts = [ Index::Entry, Index::Section, Index::Doc, Index::Link ].map(&:count)
    assert_not seed
    assert_equal counts, [ Index::Entry, Index::Section, Index::Doc, Index::Link ].map(&:count)
    assert_equal "Dashboard", Index::Entry.find_by!(slug: "home").name
  end

  test "every seed entry is valid under the index's rules" do
    seed
    Index::Entry.includes(:links).find_each { |entry| assert entry.valid?, "#{entry.slug}: #{entry.errors.full_messages}" }
  end
end
