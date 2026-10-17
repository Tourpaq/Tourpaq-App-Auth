require "test_helper"

# Who sees what in the index (SPECS.md §24.3), in the query: sections and entries for everyone signed in or for the
# chosen groups; an app's entry only with access to the app; an entry in a hidden section is hidden.
class Index::VisibilityTest < ActiveSupport::TestCase
  def viewer(user) = Index::Viewer.new(user)
  def entries_for(user) = Index::Entry.visible_to(viewer(user)).order(:slug).pluck(:slug)
  def sections_for(user) = Index::Section.visible_to(viewer(user)).order(:slug).pluck(:slug)

  test "DK Tech sees the table section; RO Dev does not, but sees the IRM entry through its access" do
    assert_equal %w[apps databases], sections_for(users(:mwi))
    assert_equal %w[irm ms-sql-master-bravo salesview], entries_for(users(:mwi))

    assert_equal %w[apps], sections_for(users(:alice))
    assert_equal %w[irm salesview], entries_for(users(:alice)), "alice is an IRM responder through RO Dev"
  end

  test "no access to the app, no entry; a disabled app counts as no access" do
    carol = users(:carol)
    assert_equal %w[salesview], entries_for(carol)
    apps(:irm).update!(disabled_at: Time.current)
    assert_equal %w[ms-sql-master-bravo salesview], entries_for(users(:mwi))
  end

  test "a direct no-access grant hides the app's entry even with a group grant" do
    Grant.create!(app: apps(:irm), subject: users(:alice), app_role: nil)
    assert_equal %w[salesview], entries_for(users(:alice))
  end

  test "an entry restricted to groups, in no section" do
    Index::Entry.create!(name: "Prod jump host", description: "SSH into prod.", address: "jump.tourpaq.com",
                         visibility: "groups", groups: [ groups(:ro_dev) ])
    assert_includes entries_for(users(:alice)), "prod-jump-host"
    assert_not_includes entries_for(users(:mwi)), "prod-jump-host"
  end

  test "groups chosen on a restricted entry inside a hidden section do not show it" do
    index_entries(:sql_bravo).update!(visibility: "groups", groups: [ groups(:ro_dev) ])
    assert_not_includes entries_for(users(:alice)), "ms-sql-master-bravo", "the section is DK Tech and RO DevOps only"
    assert_not_includes entries_for(users(:mwi)), "ms-sql-master-bravo", "mwi sees the section but not the entry"
  end

  test "a section restricted to groups with none chosen is seen by nobody" do
    index_sections(:databases).section_groups.delete_all
    assert_equal %w[apps], sections_for(users(:mwi))
    assert_not_includes entries_for(users(:mwi)), "ms-sql-master-bravo"
  end

  test "nobody, or a disabled user, sees only what is for everyone signed in" do
    assert_equal %w[salesview], entries_for(nil)
    assert_equal %w[salesview], entries_for(users(:dave_disabled))
  end

  test "deleting a group takes it out of the visibility, never widening it" do
    groups(:dk_tech).destroy!
    assert_equal %w[databases], Index::Section.where(visibility: "groups").pluck(:slug)
    assert_equal [ "RO DevOps" ], index_sections(:databases).reload.groups.map(&:name)
  end
end
