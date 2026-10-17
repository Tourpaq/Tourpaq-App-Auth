# The index content (SPECS.md §24.3), carried over from Tourpaq-App-WWW: sections (WWW "categories"), entries (WWW
# "apps") with their links, the two vocabularies shown as pills (access levels, login methods), docs in doc sections,
# and the site settings. All tables are prefixed index_ (models in Index::).
#
# New against WWW: an entry may be tied to an auth App (then it is shown only to users with access to that app), and
# sections and the other entries have a visibility: everyone signed in, or only the chosen auth groups. A section's
# layout ("cards" on the front page, or "table": a page of its own with a compact table) is what WWW's audience
# decided about presentation.
class CreateIndexContent < ActiveRecord::Migration[8.1]
  def change
    # Site-wide text: one row.
    create_table :index_sites do |t|
      t.string :title, null: false
      t.string :brand
      t.string :tagline
      t.string :footer
      t.timestamps
    end

    create_table :index_sections do |t|
      t.string :name, null: false
      t.string :slug, null: false, index: { unique: true }
      t.string :description
      t.string :layout, null: false, default: "cards"
      t.string :visibility, null: false, default: "everyone"
      t.integer :position, null: false, default: 100
      t.timestamps
    end

    create_table :index_section_groups do |t|
      t.references :section, null: false, foreign_key: { to_table: :index_sections, on_delete: :cascade }
      t.references :group, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :index_section_groups, %i[section_id group_id], unique: true

    %i[index_access_levels index_login_methods].each do |table|
      create_table table do |t|
        t.string :key, null: false, index: { unique: true }
        t.string :label, null: false
        t.string :tone, null: false, default: "neutral"
        t.integer :position, null: false, default: 100
        t.timestamps
      end
    end

    create_table :index_entries do |t|
      t.string :slug, null: false, index: { unique: true }
      t.string :name, null: false
      t.string :description, null: false
      t.string :url
      t.string :address # a host or IP range, for things that aren't web pages
      t.references :section, foreign_key: { to_table: :index_sections, on_delete: :nullify }
      t.references :app, foreign_key: { on_delete: :nullify }
      t.string :visibility, null: false, default: "everyone"
      t.string :status, null: false, default: "live"
      t.string :owner
      t.string :repo
      t.string :icon
      t.references :access_level, foreign_key: { to_table: :index_access_levels, on_delete: :nullify }
      t.references :login_method, foreign_key: { to_table: :index_login_methods, on_delete: :nullify }
      t.integer :position, null: false, default: 100
      t.text :body
      t.timestamps
    end

    create_table :index_entry_groups do |t|
      t.references :entry, null: false, foreign_key: { to_table: :index_entries, on_delete: :cascade }
      t.references :group, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :index_entry_groups, %i[entry_id group_id], unique: true

    create_table :index_links do |t|
      t.references :entry, null: false, foreign_key: { to_table: :index_entries, on_delete: :cascade }
      t.string :label, null: false
      t.string :url, null: false
      t.string :note
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :index_doc_sections do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :title, null: false
      t.integer :position, null: false, default: 100
      t.timestamps
    end

    create_table :index_docs do |t|
      t.references :doc_section, foreign_key: { to_table: :index_doc_sections, on_delete: :nullify }
      t.string :slug, null: false
      t.string :title, null: false
      t.string :summary
      t.text :body
      t.integer :position, null: false, default: 100
      t.timestamps
    end
    add_index :index_docs, %i[doc_section_id slug], unique: true
  end
end
