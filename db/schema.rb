# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_19_080001) do
  create_table "app_permissions", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "key", null: false
    t.string "label"
    t.string "group_label"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "key"], name: "index_app_permissions_on_app_id_and_key", unique: true
    t.index ["app_id"], name: "index_app_permissions_on_app_id"
  end

  create_table "app_roles", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "key", null: false
    t.string "description"
    t.integer "position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "permissions", default: [], null: false
    t.index ["app_id", "key"], name: "index_app_roles_on_app_id_and_key", unique: true
    t.index ["app_id", "position"], name: "index_app_roles_on_app_id_and_position", unique: true
    t.index ["app_id"], name: "index_app_roles_on_app_id"
  end

  create_table "apps", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.text "description"
    t.string "icon"
    t.string "url"
    t.string "role_claim", null: false
    t.boolean "show_in_launcher", default: true, null: false
    t.datetime "disabled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "multiple_roles", default: false, null: false
    t.string "admin_permission"
    t.json "token_scopes", default: ["read", "read_write"], null: false
    t.datetime "catalogue_pushed_at"
    t.index ["slug"], name: "index_apps_on_slug", unique: true
  end

  create_table "audit_events", force: :cascade do |t|
    t.integer "actor_id"
    t.string "action", null: false
    t.string "subject_type"
    t.integer "subject_id"
    t.integer "app_id"
    t.string "channel", default: "web", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.json "data", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["action", "created_at"], name: "index_audit_events_on_action_and_created_at"
    t.index ["actor_id", "created_at"], name: "index_audit_events_on_actor_id_and_created_at"
    t.index ["actor_id"], name: "index_audit_events_on_actor_id"
    t.index ["app_id", "created_at"], name: "index_audit_events_on_app_id_and_created_at"
    t.index ["app_id"], name: "index_audit_events_on_app_id"
    t.index ["created_at"], name: "index_audit_events_on_created_at"
    t.index ["subject_type", "subject_id"], name: "index_audit_events_on_subject"
  end

  create_table "authorization_codes", force: :cascade do |t|
    t.integer "client_id", null: false
    t.integer "user_id", null: false
    t.integer "session_id"
    t.string "code_digest", null: false
    t.string "redirect_uri", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.string "nonce"
    t.string "scope"
    t.datetime "auth_time"
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.index ["client_id"], name: "index_authorization_codes_on_client_id"
    t.index ["code_digest"], name: "index_authorization_codes_on_code_digest", unique: true
    t.index ["expires_at"], name: "index_authorization_codes_on_expires_at"
    t.index ["session_id"], name: "index_authorization_codes_on_session_id"
    t.index ["user_id"], name: "index_authorization_codes_on_user_id"
  end

  create_table "client_secrets", force: :cascade do |t|
    t.integer "client_id", null: false
    t.string "secret_digest", null: false
    t.string "hint", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.integer "created_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_client_secrets_on_client_id"
    t.index ["created_by_id"], name: "index_client_secrets_on_created_by_id"
    t.index ["secret_digest"], name: "index_client_secrets_on_secret_digest", unique: true
  end

  create_table "clients", force: :cascade do |t|
    t.integer "app_id"
    t.string "client_id", null: false
    t.string "kind", default: "web", null: false
    t.string "name"
    t.json "redirect_uris", default: [], null: false
    t.json "post_logout_redirect_uris", default: [], null: false
    t.datetime "disabled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_clients_on_app_id"
    t.index ["client_id"], name: "index_clients_on_client_id", unique: true
  end

  create_table "grants", force: :cascade do |t|
    t.integer "app_id", null: false
    t.string "subject_type", null: false
    t.integer "subject_id", null: false
    t.integer "app_role_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "subject_type", "subject_id", "app_role_id"], name: "index_grants_on_app_subject_and_role", unique: true
    t.index ["app_id"], name: "index_grants_on_app_id"
    t.index ["app_role_id"], name: "index_grants_on_app_role_id"
    t.index ["subject_type", "subject_id"], name: "index_grants_on_subject"
  end

  create_table "group_memberships", force: :cascade do |t|
    t.integer "group_id", null: false
    t.integer "user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "user_id"], name: "index_group_memberships_on_group_id_and_user_id", unique: true
    t.index ["group_id"], name: "index_group_memberships_on_group_id"
    t.index ["user_id"], name: "index_group_memberships_on_user_id"
  end

  create_table "groups", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_groups_on_name", unique: true
  end

  create_table "index_access_levels", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.string "tone", default: "neutral", null: false
    t.integer "position", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_index_access_levels_on_key", unique: true
  end

  create_table "index_doc_sections", force: :cascade do |t|
    t.string "key", null: false
    t.string "title", null: false
    t.integer "position", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_index_doc_sections_on_key", unique: true
  end

  create_table "index_docs", force: :cascade do |t|
    t.integer "doc_section_id"
    t.string "slug", null: false
    t.string "title", null: false
    t.string "summary"
    t.text "body"
    t.integer "position", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["doc_section_id", "slug"], name: "index_index_docs_on_doc_section_id_and_slug", unique: true
    t.index ["doc_section_id"], name: "index_index_docs_on_doc_section_id"
  end

  create_table "index_entries", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.string "description", null: false
    t.string "url"
    t.string "address"
    t.integer "section_id"
    t.integer "app_id"
    t.string "visibility", default: "everyone", null: false
    t.string "status", default: "live", null: false
    t.string "owner"
    t.string "repo"
    t.string "icon"
    t.integer "access_level_id"
    t.integer "login_method_id"
    t.integer "position", default: 100, null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_level_id"], name: "index_index_entries_on_access_level_id"
    t.index ["app_id"], name: "index_index_entries_on_app_id"
    t.index ["login_method_id"], name: "index_index_entries_on_login_method_id"
    t.index ["section_id"], name: "index_index_entries_on_section_id"
    t.index ["slug"], name: "index_index_entries_on_slug", unique: true
  end

  create_table "index_entry_groups", force: :cascade do |t|
    t.integer "entry_id", null: false
    t.integer "group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id", "group_id"], name: "index_index_entry_groups_on_entry_id_and_group_id", unique: true
    t.index ["entry_id"], name: "index_index_entry_groups_on_entry_id"
    t.index ["group_id"], name: "index_index_entry_groups_on_group_id"
  end

  create_table "index_links", force: :cascade do |t|
    t.integer "entry_id", null: false
    t.string "label", null: false
    t.string "url", null: false
    t.string "note"
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id"], name: "index_index_links_on_entry_id"
  end

  create_table "index_login_methods", force: :cascade do |t|
    t.string "key", null: false
    t.string "label", null: false
    t.string "tone", default: "neutral", null: false
    t.integer "position", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_index_login_methods_on_key", unique: true
  end

  create_table "index_section_groups", force: :cascade do |t|
    t.integer "section_id", null: false
    t.integer "group_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id"], name: "index_index_section_groups_on_group_id"
    t.index ["section_id", "group_id"], name: "index_index_section_groups_on_section_id_and_group_id", unique: true
    t.index ["section_id"], name: "index_index_section_groups_on_section_id"
  end

  create_table "index_sections", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "description"
    t.string "layout", default: "cards", null: false
    t.string "visibility", default: "everyone", null: false
    t.integer "position", default: 100, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_index_sections_on_slug", unique: true
  end

  create_table "index_sites", force: :cascade do |t|
    t.string "title", null: false
    t.string "brand"
    t.string "tagline"
    t.string "footer"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "oauth_tokens", force: :cascade do |t|
    t.integer "client_id", null: false
    t.integer "user_id", null: false
    t.string "kind", null: false
    t.string "token_digest", null: false
    t.string "token_hint"
    t.string "scope"
    t.string "chain_id", null: false
    t.integer "replaced_by_id"
    t.datetime "auth_time"
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "last_used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chain_id"], name: "index_oauth_tokens_on_chain_id"
    t.index ["client_id"], name: "index_oauth_tokens_on_client_id"
    t.index ["replaced_by_id"], name: "index_oauth_tokens_on_replaced_by_id"
    t.index ["token_digest"], name: "index_oauth_tokens_on_token_digest", unique: true
    t.index ["user_id", "revoked_at"], name: "index_oauth_tokens_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_oauth_tokens_on_user_id"
  end

  create_table "personal_tokens", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "app_id", null: false
    t.string "name", null: false
    t.string "token_digest", null: false
    t.string "token_hint", null: false
    t.string "scope", default: "read", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.integer "revoked_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_personal_tokens_on_app_id"
    t.index ["revoked_by_id"], name: "index_personal_tokens_on_revoked_by_id"
    t.index ["token_digest"], name: "index_personal_tokens_on_token_digest", unique: true
    t.index ["user_id", "revoked_at", "expires_at"], name: "index_personal_tokens_on_user_id_and_revoked_at_and_expires_at"
    t.index ["user_id"], name: "index_personal_tokens_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "kind", default: "home", null: false
    t.string "token_digest", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "entra_authenticated_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "ended_at"
    t.string "end_reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "entra_auth_time"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id", "kind", "ended_at"], name: "index_sessions_on_user_id_and_kind_and_ended_at"
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "usage_counts", force: :cascade do |t|
    t.integer "client_id", null: false
    t.date "day", null: false
    t.string "kind", null: false
    t.integer "count", default: 0, null: false
    t.index ["client_id", "day", "kind"], name: "index_usage_counts_on_client_id_and_day_and_kind", unique: true
    t.index ["client_id"], name: "index_usage_counts_on_client_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "sub", null: false
    t.string "entra_oid"
    t.string "entra_tid"
    t.string "email", null: false
    t.string "name"
    t.string "upn"
    t.boolean "admin", default: false, null: false
    t.datetime "disabled_at"
    t.datetime "sessions_valid_after"
    t.datetime "last_login_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["entra_oid", "entra_tid"], name: "index_users_on_entra_oid_and_entra_tid", unique: true
    t.index ["sub"], name: "index_users_on_sub", unique: true
  end

  add_foreign_key "app_permissions", "apps"
  add_foreign_key "app_roles", "apps"
  add_foreign_key "audit_events", "apps"
  add_foreign_key "audit_events", "users", column: "actor_id"
  add_foreign_key "authorization_codes", "clients"
  add_foreign_key "authorization_codes", "sessions"
  add_foreign_key "authorization_codes", "users"
  add_foreign_key "client_secrets", "clients"
  add_foreign_key "client_secrets", "users", column: "created_by_id"
  add_foreign_key "clients", "apps"
  add_foreign_key "grants", "app_roles"
  add_foreign_key "grants", "apps"
  add_foreign_key "group_memberships", "groups"
  add_foreign_key "group_memberships", "users"
  add_foreign_key "index_docs", "index_doc_sections", column: "doc_section_id", on_delete: :nullify
  add_foreign_key "index_entries", "apps", on_delete: :nullify
  add_foreign_key "index_entries", "index_access_levels", column: "access_level_id", on_delete: :nullify
  add_foreign_key "index_entries", "index_login_methods", column: "login_method_id", on_delete: :nullify
  add_foreign_key "index_entries", "index_sections", column: "section_id", on_delete: :nullify
  add_foreign_key "index_entry_groups", "groups", on_delete: :cascade
  add_foreign_key "index_entry_groups", "index_entries", column: "entry_id", on_delete: :cascade
  add_foreign_key "index_links", "index_entries", column: "entry_id", on_delete: :cascade
  add_foreign_key "index_section_groups", "groups", on_delete: :cascade
  add_foreign_key "index_section_groups", "index_sections", column: "section_id", on_delete: :cascade
  add_foreign_key "oauth_tokens", "clients"
  add_foreign_key "oauth_tokens", "oauth_tokens", column: "replaced_by_id"
  add_foreign_key "oauth_tokens", "users"
  add_foreign_key "personal_tokens", "apps"
  add_foreign_key "personal_tokens", "users"
  add_foreign_key "personal_tokens", "users", column: "revoked_by_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "usage_counts", "clients"
end
