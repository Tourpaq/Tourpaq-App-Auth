# Who sees the index (SPECS.md §24.3): a group can be marked as Tourpaq staff, and the index's "everyone" content is
# then for staff only (members of a staff group, and admins). Everybody else (customers, contractors) sees their own
# apps and what is shown to their groups. Doc sections get the same visibility as sections (everyone | groups).
#
# Every group that exists today is internal (DK Tech, RO DevOps, RO Dev, …), so they all become staff and nobody who
# sees the index today loses anything. A group created from now on is not staff until an admin ticks it.
class AddIndexAudiences < ActiveRecord::Migration[8.1]
  class MigrationGroup < ActiveRecord::Base
    self.table_name = "groups"
  end

  def up
    add_column :groups, :staff, :boolean, default: false, null: false
    MigrationGroup.reset_column_information
    MigrationGroup.update_all(staff: true)

    add_column :index_doc_sections, :visibility, :string, default: "everyone", null: false
    create_table :index_doc_section_groups do |t|
      t.references :doc_section, null: false, foreign_key: { to_table: :index_doc_sections, on_delete: :cascade }
      t.references :group, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :index_doc_section_groups, %i[doc_section_id group_id], unique: true
  end

  def down
    drop_table :index_doc_section_groups
    remove_column :index_doc_sections, :visibility
    remove_column :groups, :staff
  end
end
