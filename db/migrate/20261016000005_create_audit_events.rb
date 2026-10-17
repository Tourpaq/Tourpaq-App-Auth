class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    # §12: who did what, from where. Kept indefinitely. app_id lets admins filter by app.
    create_table :audit_events do |t|
      t.references :actor, foreign_key: { to_table: :users }
      t.string :action, null: false
      t.references :subject, polymorphic: true
      t.references :app, foreign_key: true
      t.string :channel, null: false, default: "web" # web, admin, api, console, system
      t.string :ip_address
      t.string :user_agent
      t.json :data, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_events, :created_at
    add_index :audit_events, [ :action, :created_at ]
    add_index :audit_events, [ :actor_id, :created_at ]
    add_index :audit_events, [ :app_id, :created_at ]
  end
end
