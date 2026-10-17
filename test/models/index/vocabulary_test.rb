require "test_helper"

# The two pills' vocabularies and sections (WWW's vocabulary test).
class Index::VocabularyTest < ActiveSupport::TestCase
  test "keys are normalised loosely, as the markdown site matched them" do
    level = Index::AccessLevel.create!(label: "Azure VPN access", key: "Azure VPN", tone: "ok")
    assert_equal "azure-vpn", level.key
  end

  test "key defaults to the label" do
    assert_equal "tailscale", Index::AccessLevel.create!(label: "Tailscale", tone: "ok").key
  end

  test "tone must be known" do
    assert_not Index::LoginMethod.new(label: "Magic", tone: "purple").valid?
  end

  test "deleting a level leaves its entries without one" do
    index_access_levels(:netbird).destroy!
    assert_nil index_entries(:salesview).reload.access_level
  end

  test "a section's layout and visibility are known values" do
    assert_not Index::Section.new(name: "X", layout: "list").valid?
    assert_not Index::Section.new(name: "X", visibility: "managers").valid?
    assert index_sections(:databases).table?
    assert_equal "technical", index_sections(:databases).audience
    assert_equal "DK Tech, RO DevOps", index_sections(:databases).visibility_label
  end

  test "deleting a section keeps its entries, without a section" do
    index_sections(:databases).destroy!
    assert_nil index_entries(:sql_bravo).reload.section
  end
end
