require "test_helper"

# Index entries (SPECS.md §24.3; WWW's App model).
class Index::EntryTest < ActiveSupport::TestCase
  def build(**attrs)
    Index::Entry.new({ name: "Booking Monitor", description: "Watches the queue.", url: "https://bm.tourpaq.com" }.merge(attrs))
  end

  test "slug is made from the name" do
    entry = build
    assert entry.valid?
    assert_equal "booking-monitor", entry.slug
  end

  test "needs a url, an address or a link" do
    entry = build(url: nil)
    assert_not entry.valid?
    assert_match "points somewhere", entry.errors[:base].join

    assert build(url: nil, address: "10.50.1.10/32").valid?
    entry = build(url: nil)
    entry.links.build(label: "Overview", url: "https://grafana.tourpaq.com/d/1")
    assert entry.valid?
  end

  test "rejects script urls, since editors are not fully trusted (WWW's URL format)" do
    assert_not build(url: "javascript:alert(1)").valid?
    assert_not build(repo: "data:text/html,hi").valid?
    assert_not build(url: "https://x.example/\"onmouseover=\"x").valid?
    link = build.links.build(label: "x", url: "javascript:alert(1)")
    assert_not link.valid?
    assert build(url: "/docs/deployment/deploying-a-new-app").valid?
    assert build(url: "http://app.hetzner.tp").valid?
  end

  test "icon is a single emoji or an image url" do
    assert build(icon: "📈").valid?
    assert build(icon: "https://grafana.com/static/assets/img/fav32.png").valid?
    assert_not build(icon: "www.example.com/icon.png").valid?
    assert_not build(icon: "a whole sentence").valid?
    assert_not build(icon: "javascript:alert(1)").valid?
  end

  test "link labels are unique within an entry, including unsaved ones" do
    entry = build
    entry.links.build(label: "Overview", url: "https://a.example")
    entry.links.build(label: "overview", url: "https://b.example")
    assert_not entry.valid?
    assert_match "share the label", entry.errors[:base].join
  end

  test "blank strings are stored as nil" do
    entry = build(address: "  ", owner: "")
    entry.valid?
    assert_nil entry.address
    assert_nil entry.owner
  end

  test "status and visibility must be known" do
    assert_not build(status: "deprecated").valid?
    assert_not build(visibility: "managers").valid?
  end

  test "an app's entry has no visibility of its own: it follows the app's access" do
    entry = build(app: apps(:kpi), visibility: "groups", groups: [ groups(:ro_devops) ])
    entry.save!
    assert_equal "everyone", entry.visibility
    assert_empty entry.reload.groups
    assert_equal "Users with access to KPI", entry.visibility_label
  end

  test "search matches name, address, owner, section and link labels, all terms" do
    assert_equal [ index_entries(:sql_bravo) ], Index::Entry.search("sql bravo").to_a
    assert_equal [ index_entries(:sql_bravo) ], Index::Entry.search("sql-bp-we").to_a
    assert_equal [ index_entries(:salesview) ], Index::Entry.search("sam").to_a
    assert_equal [ index_entries(:sql_bravo) ], Index::Entry.search("databases").to_a
    assert_equal [ index_entries(:salesview) ], Index::Entry.search("booking admin").to_a
    assert_empty Index::Entry.search("sql staging")
    assert_empty Index::Entry.search("  ")
    assert_empty Index::Entry.search("100%_")
  end

  test "to_param keeps the saved slug while a rename is unsaved" do
    entry = index_entries(:salesview)
    entry.slug = "renamed"
    assert_equal "salesview", entry.to_param
  end
end
