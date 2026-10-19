require "test_helper"

# Who sees what in the index (SPECS.md §24.3), in the query: sections, doc sections and entries for all Tourpaq staff
# (admins and members of a staff group) or for the chosen groups; an app's entry only with access to the app; an entry
# in a hidden section is hidden. Everybody else (customers, contractors) sees their apps and their groups' content.
class Index::VisibilityTest < ActiveSupport::TestCase
  def viewer(user) = Index::Viewer.new(user)
  def entries_for(user) = Index::Entry.visible_to(viewer(user)).order(:slug).pluck(:slug)
  def sections_for(user) = Index::Section.visible_to(viewer(user)).order(:slug).pluck(:slug)
  def docs_for(user) = Index::Doc.visible_to(viewer(user)).order(:slug).pluck(:slug)

  def contractor
    group = Group.create!(name: "Contractors")
    User.create!(email: "dev@contractor.example", name: "Contractor").tap { group.users << _1 }
  end

  test "DK Tech sees the table section; RO Dev does not, but sees the IRM entry through its access" do
    assert_equal %w[apps databases], sections_for(users(:mwi))
    assert_equal %w[irm ms-sql-master-bravo salesview], entries_for(users(:mwi))

    assert_equal %w[apps], sections_for(users(:alice))
    assert_equal %w[irm salesview], entries_for(users(:alice)), "alice is an IRM responder through RO Dev"
  end

  test "no access to the app, no entry; a disabled app counts as no access" do
    assert_equal %w[irm ms-sql-master-bravo salesview], entries_for(users(:mwi))
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

  test "nobody, or a disabled user, sees nothing" do
    [ nil, users(:dave_disabled) ].each do |user|
      assert_not viewer(user).staff?
      assert_empty entries_for(user)
      assert_empty sections_for(user)
      assert_empty docs_for(user)
    end
  end

  test "staff: an admin, or a member of a group marked staff" do
    assert viewer(users(:alice)).staff?, "RO Dev is staff"
    assert_not viewer(users(:carol)).staff?, "in no group"
    groups(:ro_dev).update!(staff: false)
    assert_not viewer(users(:alice)).staff?
    users(:carol).update!(admin: true)
    assert viewer(users(:carol)).staff?, "an admin in no group"
  end

  test "someone who is not staff (a customer) sees only their apps' entries, nothing for all staff" do
    carol = users(:carol)
    assert_empty entries_for(carol)
    assert_empty sections_for(carol)
    assert_empty docs_for(carol)

    # Their app's entry needs its section too; the front page then shows the app itself under "Your apps".
    Grant.create!(app: apps(:irm), subject: carol, app_role: app_roles(:irm_viewer))
    assert_empty entries_for(carol), "the IRM entry is in Apps, which is for all staff"
    index_entries(:irm).update!(section: nil)
    assert_equal %w[irm], entries_for(carol)
  end

  test "a group that is not staff (contractors) sees what is shown to it, and nothing for all staff" do
    dev = contractor
    group = Group.find_by!(name: "Contractors")
    assert_empty sections_for(dev)
    section = Index::Section.create!(name: "For contractors", visibility: "groups", groups: [ group ])
    Index::Entry.create!(name: "GitLab", description: "Code.", url: "https://gitlab.example", section: section,
                         visibility: "everyone")
    Index::Entry.create!(name: "Staging", description: "Staging.", url: "https://staging.example", section: section,
                         visibility: "groups", groups: [ group ])
    assert_equal %w[for-contractors], sections_for(dev)
    assert_equal %w[staging], entries_for(dev), "GitLab is for all staff, even inside their section"
    assert_not_includes sections_for(users(:mwi)), "for-contractors", "staff do not see another group's section"
    assert_not_includes entries_for(users(:mwi)), "staging"
  end

  test "docs follow their doc section: all staff, or the chosen groups; a doc in no section is for staff" do
    assert_equal %w[deploying-a-new-app], docs_for(users(:alice))
    deployment = index_doc_sections(:deployment)
    deployment.update!(visibility: "groups", groups: [ groups(:dk_tech) ])
    assert_empty docs_for(users(:alice))
    assert_equal %w[deploying-a-new-app], docs_for(users(:mwi))

    dev = contractor
    deployment.groups << Group.find_by!(name: "Contractors")
    loose = Index::Doc.create!(title: "Loose page", body: "x")
    assert_equal %w[deploying-a-new-app], docs_for(dev)
    assert_equal %w[deploying-a-new-app loose-page], docs_for(users(:mwi))

    deployment.update!(groups: [])
    assert_equal [ loose.slug ], docs_for(users(:mwi)), "restricted to no group: nobody"
  end

  test "deleting a group takes it out of the visibility, never widening it" do
    index_doc_sections(:deployment).update!(visibility: "groups", groups: [ groups(:dk_tech), groups(:ro_dev) ])
    groups(:dk_tech).destroy!
    assert_equal [ "RO Dev" ], index_doc_sections(:deployment).reload.groups.map(&:name)
    assert_equal %w[databases], Index::Section.where(visibility: "groups").pluck(:slug)
    assert_equal [ "RO DevOps" ], index_sections(:databases).reload.groups.map(&:name)
  end
end
