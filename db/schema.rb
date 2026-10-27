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

ActiveRecord::Schema.define(version: 2026_11_04_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "account_aliases", force: :cascade do |t|
    t.bigint "account_id"
    t.string "acct", default: "", null: false
    t.string "uri", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_aliases_on_account_id"
  end

  create_table "account_conversations", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "conversation_id"
    t.bigint "participant_account_ids", default: [], null: false, array: true
    t.bigint "status_ids", default: [], null: false, array: true
    t.bigint "last_status_id"
    t.integer "lock_version", default: 0, null: false
    t.boolean "unread", default: false, null: false
    t.index ["account_id", "conversation_id", "participant_account_ids"], name: "index_unique_conversations", unique: true
    t.index ["conversation_id"], name: "index_account_conversations_on_conversation_id"
  end

  create_table "account_deletion_requests", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_deletion_requests_on_account_id"
  end

  create_table "account_domain_blocks", force: :cascade do |t|
    t.string "domain"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.index ["account_id", "domain"], name: "index_account_domain_blocks_on_account_id_and_domain", unique: true
  end

  create_table "account_identity_proofs", force: :cascade do |t|
    t.bigint "account_id"
    t.string "provider", default: "", null: false
    t.string "provider_username", default: "", null: false
    t.text "token", default: "", null: false
    t.boolean "verified", default: false, null: false
    t.boolean "live", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "provider", "provider_username"], name: "index_account_proofs_on_account_and_provider_and_username", unique: true
  end

  create_table "account_migrations", force: :cascade do |t|
    t.bigint "account_id"
    t.string "acct", default: "", null: false
    t.bigint "followers_count", default: 0, null: false
    t.bigint "target_account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "action_review_executed_at"
    t.index ["account_id"], name: "index_account_migrations_on_account_id"
    t.index ["target_account_id"], name: "index_account_migrations_on_target_account_id"
  end

  create_table "account_moderation_notes", force: :cascade do |t|
    t.text "content", null: false
    t.bigint "account_id", null: false
    t.bigint "target_account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_moderation_notes_on_account_id"
    t.index ["target_account_id"], name: "index_account_moderation_notes_on_target_account_id"
  end

  create_table "account_notes", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "target_account_id"
    t.text "comment", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "target_account_id"], name: "index_account_notes_on_account_id_and_target_account_id", unique: true
    t.index ["target_account_id"], name: "index_account_notes_on_target_account_id"
  end

  create_table "account_pins", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "target_account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "target_account_id"], name: "index_account_pins_on_account_id_and_target_account_id", unique: true
    t.index ["target_account_id"], name: "index_account_pins_on_target_account_id"
  end

  create_table "account_stats", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "statuses_count", default: 0, null: false
    t.bigint "following_count", default: 0, null: false
    t.bigint "followers_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_status_at"
    t.bigint "subscribing_count", default: 0, null: false
    t.string "outbox_next_page_url"
    t.index ["account_id"], name: "index_account_stats_on_account_id", unique: true
  end

  create_table "account_statuses_cleanup_policies", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "min_status_age", default: 1209600, null: false
    t.boolean "keep_direct", default: true, null: false
    t.boolean "keep_pinned", default: true, null: false
    t.boolean "keep_polls", default: false, null: false
    t.boolean "keep_media", default: false, null: false
    t.boolean "keep_self_fav", default: true, null: false
    t.boolean "keep_self_bookmark", default: true, null: false
    t.integer "min_favs"
    t.integer "min_reblogs"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["account_id"], name: "index_account_statuses_cleanup_policies_on_account_id"
  end

  create_table "account_subscribes", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "target_account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "list_id"
    t.boolean "show_reblogs", default: true, null: false
    t.boolean "media_only", default: false, null: false
    t.index ["account_id"], name: "index_account_subscribes_on_account_id"
    t.index ["list_id"], name: "index_account_subscribes_on_list_id"
    t.index ["target_account_id"], name: "index_account_subscribes_on_target_account_id"
  end

  create_table "account_warning_presets", force: :cascade do |t|
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "title", default: "", null: false
  end

  create_table "account_warnings", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "target_account_id"
    t.integer "action", default: 0, null: false
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_account_warnings_on_account_id"
    t.index ["target_account_id"], name: "index_account_warnings_on_target_account_id"
  end

  create_table "accounts", id: :bigint, default: -> { "timestamp_id('accounts'::text)" }, force: :cascade do |t|
    t.string "username", default: "", null: false
    t.string "domain"
    t.text "private_key"
    t.text "public_key", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "note", default: "", null: false
    t.string "display_name", default: "", null: false
    t.string "uri", default: "", null: false
    t.string "url"
    t.string "avatar_file_name"
    t.string "avatar_content_type"
    t.integer "avatar_file_size"
    t.datetime "avatar_updated_at"
    t.string "header_file_name"
    t.string "header_content_type"
    t.integer "header_file_size"
    t.datetime "header_updated_at"
    t.string "avatar_remote_url"
    t.boolean "locked", default: false, null: false
    t.string "header_remote_url", default: "", null: false
    t.datetime "last_webfingered_at"
    t.string "inbox_url", default: "", null: false
    t.string "outbox_url", default: "", null: false
    t.string "shared_inbox_url", default: "", null: false
    t.string "followers_url", default: "", null: false
    t.integer "protocol", default: 0, null: false
    t.boolean "memorial", default: false, null: false
    t.bigint "moved_to_account_id"
    t.string "featured_collection_url"
    t.jsonb "fields"
    t.string "actor_type"
    t.boolean "discoverable"
    t.string "also_known_as", array: true
    t.datetime "silenced_at"
    t.datetime "suspended_at"
    t.integer "trust_level"
    t.boolean "hide_collections"
    t.integer "avatar_storage_schema_version"
    t.integer "header_storage_schema_version"
    t.string "devices_url"
    t.integer "suspension_origin"
    t.datetime "sensitized_at"
    t.jsonb "settings", default: "{}", null: false
    t.integer "silence_mode", default: 0, null: false
    t.integer "searchability", default: 3, null: false
    t.string "featured_tags_collection_url"
    t.string "avatar_thumbhash"
    t.string "header_thumbhash"
    t.boolean "indexable", default: false, null: false
    t.integer "priority", default: 0, null: false
    t.boolean "trendable"
    t.datetime "reviewed_at"
    t.datetime "requested_review_at"
    t.string "affiliations_url"
    t.datetime "affiliations_fetched_at"
    t.string "can_create_affiliation"
    t.string "can_view_affiliation"
    t.datetime "permission_definitions_fetched_at"
    t.index "(((setweight(to_tsvector('simple'::regconfig, (display_name)::text), 'A'::\"char\") || setweight(to_tsvector('simple'::regconfig, (username)::text), 'B'::\"char\")) || setweight(to_tsvector('simple'::regconfig, (COALESCE(domain, ''::character varying))::text), 'C'::\"char\")))", name: "search_index", using: :gin
    t.index "lower((username)::text), COALESCE(lower((domain)::text), ''::text)", name: "index_accounts_on_username_and_domain_lower", unique: true
    t.index ["domain", "id"], name: "index_accounts_on_domain_and_id"
    t.index ["moved_to_account_id"], name: "index_accounts_on_moved_to_account_id"
    t.index ["searchability"], name: "index_accounts_on_searchability"
    t.index ["settings"], name: "index_accounts_on_settings", using: :gin
    t.index ["uri"], name: "index_accounts_on_uri"
    t.index ["url"], name: "index_accounts_on_url"
  end

  create_table "accounts_tags", id: false, force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "tag_id", null: false
    t.index ["account_id", "tag_id"], name: "index_accounts_tags_on_account_id_and_tag_id"
    t.index ["tag_id", "account_id"], name: "index_accounts_tags_on_tag_id_and_account_id", unique: true
  end

  create_table "action_review_requests", force: :cascade do |t|
    t.string "operation_type", null: false
    t.integer "state", default: 0, null: false
    t.bigint "actor_account_id"
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.string "trigger", null: false
    t.string "signal_level", null: false
    t.string "policy_mode", null: false
    t.string "policy_version", null: false
    t.string "evaluator_version"
    t.jsonb "reason_codes", default: [], null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "requested_at", null: false
    t.datetime "reviewed_at"
    t.bigint "reviewer_account_id"
    t.text "decision_note"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["actor_account_id"], name: "index_action_review_requests_on_actor_account_id"
    t.index ["operation_type", "resource_type", "resource_id"], name: "index_action_review_requests_on_pending_resource", unique: true, where: "(state = 0)"
    t.index ["reviewer_account_id"], name: "index_action_review_requests_on_reviewer_account_id"
  end

  create_table "admin_action_logs", force: :cascade do |t|
    t.bigint "account_id"
    t.string "action", default: "", null: false
    t.string "target_type"
    t.bigint "target_id"
    t.text "recorded_changes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_admin_action_logs_on_account_id"
    t.index ["target_type", "target_id"], name: "index_admin_action_logs_on_target_type_and_target_id"
  end

  create_table "announcement_mutes", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "announcement_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "announcement_id"], name: "index_announcement_mutes_on_account_id_and_announcement_id", unique: true
    t.index ["announcement_id"], name: "index_announcement_mutes_on_announcement_id"
  end

  create_table "announcement_reactions", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "announcement_id"
    t.string "name", default: "", null: false
    t.bigint "custom_emoji_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "announcement_id", "name"], name: "index_announcement_reactions_on_account_id_and_announcement_id", unique: true
    t.index ["announcement_id"], name: "index_announcement_reactions_on_announcement_id"
    t.index ["custom_emoji_id"], name: "index_announcement_reactions_on_custom_emoji_id"
  end

  create_table "announcements", force: :cascade do |t|
    t.text "text", default: "", null: false
    t.boolean "published", default: false, null: false
    t.boolean "all_day", default: false, null: false
    t.datetime "scheduled_at"
    t.datetime "starts_at"
    t.datetime "ends_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "published_at"
    t.bigint "status_ids", array: true
  end

  create_table "backups", force: :cascade do |t|
    t.bigint "user_id"
    t.string "dump_file_name"
    t.string "dump_content_type"
    t.bigint "dump_file_size"
    t.datetime "dump_updated_at"
    t.boolean "processed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "blocks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "target_account_id", null: false
    t.string "uri"
    t.index ["account_id", "target_account_id"], name: "index_blocks_on_account_id_and_target_account_id", unique: true
    t.index ["target_account_id"], name: "index_blocks_on_target_account_id"
  end

  create_table "bookmarks", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "status_id"], name: "index_bookmarks_on_account_id_and_status_id", unique: true
    t.index ["status_id"], name: "index_bookmarks_on_status_id"
  end

  create_table "canonical_email_blocks", force: :cascade do |t|
    t.string "canonical_email_hash", default: "", null: false
    t.bigint "reference_account_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["canonical_email_hash"], name: "index_canonical_email_blocks_on_canonical_email_hash", unique: true
    t.index ["reference_account_id"], name: "index_canonical_email_blocks_on_reference_account_id"
  end

  create_table "circle_accounts", force: :cascade do |t|
    t.bigint "circle_id", null: false
    t.bigint "account_id", null: false
    t.bigint "follow_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "circle_id"], name: "index_circle_accounts_on_account_id_and_circle_id", unique: true
    t.index ["account_id"], name: "index_circle_accounts_on_account_id"
    t.index ["circle_id", "account_id"], name: "index_circle_accounts_on_circle_id_and_account_id"
    t.index ["circle_id"], name: "index_circle_accounts_on_circle_id"
    t.index ["follow_id"], name: "index_circle_accounts_on_follow_id"
  end

  create_table "circles", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "title", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_circles_on_account_id"
  end

  create_table "conversation_mutes", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.bigint "account_id", null: false
    t.index ["account_id", "conversation_id"], name: "index_conversation_mutes_on_account_id_and_conversation_id", unique: true
  end

  create_table "conversations", id: :bigint, default: -> { "timestamp_id('conversations'::text)" }, force: :cascade do |t|
    t.string "uri"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "parent_status_id"
    t.bigint "parent_account_id"
    t.string "inbox_url"
    t.index ["uri"], name: "index_conversations_on_uri", unique: true
  end

  create_table "custom_emoji_categories", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "view_style", default: 0, null: false
    t.index ["name"], name: "index_custom_emoji_categories_on_name", unique: true
  end

  create_table "custom_emojis", force: :cascade do |t|
    t.string "shortcode", default: "", null: false
    t.string "domain"
    t.string "image_file_name"
    t.string "image_content_type"
    t.integer "image_file_size"
    t.datetime "image_updated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "disabled", default: false, null: false
    t.string "uri"
    t.string "image_remote_url"
    t.boolean "visible_in_picker", default: true, null: false
    t.bigint "category_id"
    t.integer "image_storage_schema_version"
    t.integer "width"
    t.integer "height"
    t.string "thumbhash"
    t.integer "copy_permission", default: 0, null: false
    t.string "aliases", default: [], null: false, array: true
    t.jsonb "meta", default: {}, null: false
    t.string "alternate_name", default: "", null: false
    t.string "ruby", default: "", null: false
    t.string "license", default: "", null: false
    t.string "usage_info", default: "", null: false
    t.string "creator", default: "", null: false
    t.string "description", default: "", null: false
    t.string "copyright_notice", default: "", null: false
    t.string "credit_text", default: "", null: false
    t.string "is_based_on", default: "", null: false
    t.boolean "sensitive", default: false, null: false
    t.string "related_links", default: [], null: false, array: true
    t.datetime "last_fetched_at"
    t.string "reading", default: "", null: false, collation: "ja-x-icu"
    t.index ["meta"], name: "index_custom_emoji_on_meta", using: :gin
    t.index ["reading"], name: "index_custom_emoji_on_reading", where: "((domain IS NULL) AND (disabled = false) AND visible_in_picker)"
    t.index ["shortcode", "domain"], name: "index_custom_emojis_on_shortcode_and_domain", unique: true
  end

  create_table "custom_filter_keywords", force: :cascade do |t|
    t.bigint "custom_filter_id", null: false
    t.text "keyword", default: "", null: false
    t.boolean "whole_word", default: true, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["custom_filter_id"], name: "index_custom_filter_keywords_on_custom_filter_id"
  end

  create_table "custom_filter_statuses", force: :cascade do |t|
    t.bigint "custom_filter_id", null: false
    t.bigint "status_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["custom_filter_id"], name: "index_custom_filter_statuses_on_custom_filter_id"
    t.index ["status_id"], name: "index_custom_filter_statuses_on_status_id"
  end

  create_table "custom_filters", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "expires_at"
    t.text "phrase", default: "", null: false
    t.string "context", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "action", default: 0, null: false
    t.index ["account_id"], name: "index_custom_filters_on_account_id"
  end

  create_table "devices", force: :cascade do |t|
    t.bigint "access_token_id"
    t.bigint "account_id"
    t.string "device_id", default: "", null: false
    t.string "name", default: "", null: false
    t.text "fingerprint_key", default: "", null: false
    t.text "identity_key", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token_id"], name: "index_devices_on_access_token_id"
    t.index ["account_id"], name: "index_devices_on_account_id"
  end

  create_table "domain_allows", force: :cascade do |t|
    t.string "domain", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_domain_allows_on_domain", unique: true
  end

  create_table "domain_blocks", force: :cascade do |t|
    t.string "domain", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "severity", default: 0
    t.boolean "reject_media", default: false, null: false
    t.boolean "reject_reports", default: false, null: false
    t.text "private_comment"
    t.text "public_comment"
    t.boolean "obfuscate", default: false, null: false
    t.index ["domain"], name: "index_domain_blocks_on_domain", unique: true
  end

  create_table "domain_subscribes", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "list_id"
    t.string "domain", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "exclude_reblog", default: true
    t.boolean "media_only", default: false, null: false
    t.index ["account_id"], name: "index_domain_subscribes_on_account_id"
    t.index ["list_id"], name: "index_domain_subscribes_on_list_id"
  end

  create_table "email_domain_blocks", force: :cascade do |t|
    t.string "domain", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "parent_id"
    t.boolean "allow_with_approval", default: false, null: false
    t.index ["domain"], name: "index_email_domain_blocks_on_domain", unique: true
  end

  create_table "emoji_reactions", id: :bigint, default: -> { "timestamp_id('emoji_reactions'::text)" }, force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.string "name", default: "", null: false
    t.bigint "custom_emoji_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "uri"
    t.index ["account_id", "status_id", "name"], name: "index_emoji_reactions_on_account_id_and_status_id", unique: true
    t.index ["account_id"], name: "index_emoji_reactions_on_account_id"
    t.index ["custom_emoji_id"], name: "index_emoji_reactions_on_custom_emoji_id"
    t.index ["status_id"], name: "index_emoji_reactions_on_status_id"
  end

  # Rails 6.1 cannot represent PostgreSQL INCLUDE indexes.
  # Do not replace these statements with the 3-column t.index definitions emitted by db:schema:dump.
  # The third column is INCLUDE payload, not a btree key.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_emoji_reactions_on_account_status_include_id
    ON emoji_reactions (account_id, status_id)
    INCLUDE (id)
  SQL

  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_emoji_reactions_on_account_id_and_id_include_status_id
    ON emoji_reactions (account_id, id)
    INCLUDE (status_id)
  SQL

  create_table "encrypted_messages", id: :bigint, default: -> { "timestamp_id('encrypted_messages'::text)" }, force: :cascade do |t|
    t.bigint "device_id"
    t.bigint "from_account_id"
    t.string "from_device_id", default: "", null: false
    t.integer "type", default: 0, null: false
    t.text "body", default: "", null: false
    t.text "digest", default: "", null: false
    t.text "message_franking", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_encrypted_messages_on_device_id"
    t.index ["from_account_id"], name: "index_encrypted_messages_on_from_account_id"
  end

  create_table "external_actors", force: :cascade do |t|
    t.string "protocol", null: false
    t.text "native_id", null: false
    t.string "handle"
    t.string "display_name"
    t.text "profile_url"
    t.text "avatar_remote_url"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["protocol", "native_id"], name: "index_external_actors_on_protocol_and_native_id", unique: true
    t.check_constraint "(protocol)::text = ANY ((ARRAY['rss'::character varying, 'atom'::character varying])::text[])", name: "external_actors_protocol_check"
  end

  create_table "external_feed_routes", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "external_subscription_id", null: false
    t.string "destination", null: false
    t.bigint "list_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["list_id"], name: "index_external_feed_routes_on_list_id"
    t.index ["user_id", "external_subscription_id"], name: "index_external_feed_routes_on_home", unique: true, where: "(((destination)::text = 'home'::text) AND (list_id IS NULL))"
    t.index ["user_id", "external_subscription_id", "list_id"], name: "index_external_feed_routes_on_list", unique: true, where: "(((destination)::text = 'list'::text) AND (list_id IS NOT NULL))"
    t.check_constraint "(((destination)::text = 'home'::text) AND (list_id IS NULL)) OR (((destination)::text = 'list'::text) AND (list_id IS NOT NULL))", name: "external_feed_routes_destination_shape"
  end

  create_table "external_identities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", limit: 64, null: false
    t.string "subject", limit: 2048, null: false
    t.string "issuer", limit: 512, null: false
    t.string "resource_origin", limit: 512, null: false
    t.string "handle", limit: 253
    t.string "display_name", limit: 200
    t.bigint "credential_id"
    t.string "granted_scopes", default: [], null: false, array: true
    t.datetime "disconnected_at"
    t.string "terms_state", limit: 32, default: "unreviewed", null: false
    t.string "status", limit: 64, default: "connected", null: false
    t.datetime "session_bound_at"
    t.bigint "bound_attempt_id"
    t.datetime "last_checked_at"
    t.string "last_error_code", limit: 64
    t.string "revocation_state", limit: 64
    t.string "token_endpoint", limit: 512, null: false
    t.string "revocation_endpoint", limit: 512
    t.integer "refresh_generation", default: 0, null: false
    t.datetime "refresh_started_at"
    t.datetime "access_expires_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["credential_id"], name: "index_external_identities_on_credential_id"
    t.index ["user_id", "provider", "subject"], name: "index_external_identities_on_owner_provider_subject", unique: true
    t.index ["user_id"], name: "index_external_identities_on_user_id"
  end

  create_table "external_link_share_policies", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.boolean "enabled", default: false, null: false
    t.string "visibility", default: "unlisted", null: false
    t.integer "revision", default: 0, null: false
    t.datetime "consented_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["user_id"], name: "index_link_share_policies_on_user_id", unique: true
    t.check_constraint "enabled = false OR consented_at IS NOT NULL", name: "link_share_policies_consent_check"
    t.check_constraint "revision >= 0", name: "link_share_policies_revision_check"
    t.check_constraint "visibility IN ('public', 'unlisted')", name: "link_share_policies_visibility_check"
  end

  create_table "external_media_assets", force: :cascade do |t|
    t.string "url_digest", null: false
    t.string "kind", null: false
    t.string "state", default: "ready", null: false
    t.string "content_type"
    t.bigint "byte_size"
    t.string "fingerprint"
    t.integer "width"
    t.integer "height"
    t.string "failure_code"
    t.string "failed_revision"
    t.integer "attempt_count", default: 0, null: false
    t.datetime "fetched_at"
    t.text "validator_etag"
    t.text "validator_last_modified"
    t.datetime "validated_at"
    t.datetime "revalidate_after"
    t.integer "revalidate_attempt", default: 0, null: false
    t.integer "generation", default: 1, null: false
    t.string "candidate_fingerprint"
    t.jsonb "attempt_log", default: [], null: false
    t.string "logical_digest"
    t.string "file_file_name"
    t.string "file_content_type"
    t.bigint "file_file_size"
    t.datetime "file_updated_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["url_digest"], name: "index_external_media_assets_on_url_digest", unique: true
    t.check_constraint "generation >= 1", name: "external_media_assets_generation_check"
    t.check_constraint "revalidate_attempt >= 0", name: "external_media_assets_revalidate_attempt_check"
  end

  # logical_digest is nullable and has no default. A generation swap sets it
  # to the article URL digest while url_digest is still incoming:{id}.
  # Scheduler::ExternalBridgeRSSMediaRevalidateScheduler orders ready images
  # that already have an external_media_asset_resources row by validated_at
  # NULLS FIRST, then applies LIMIT. Keep this predicate. Do not replace it
  # with a dump.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_ext_media_assets_on_image_revalidate
    ON external_media_assets (validated_at ASC NULLS FIRST, id)
    WHERE state = 'ready' AND kind = 'image'
  SQL

  create_table "external_media_asset_resources", force: :cascade do |t|
    t.bigint "external_media_asset_id", null: false
    t.bigint "external_resource_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_media_asset_id", "external_resource_id"], name: "index_ext_media_asset_resources_on_asset_and_resource", unique: true
    t.index ["external_resource_id"], name: "index_ext_media_asset_resources_on_resource"
  end

  create_table "external_media_gc_intents", force: :cascade do |t|
    t.string "target_type", limit: 32, null: false
    t.bigint "target_id", null: false
    t.string "reason", limit: 32, null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.bigint "owner_account_id"
    t.bigint "captured_status_id"
    t.bigint "source_attachment_id"
    t.bigint "captured_projection_id"
    t.bigint "external_subscription_deletion_id"
    t.datetime "available_at", null: false
    t.integer "attempt_count", default: 0, null: false
    t.string "last_error_code", limit: 64
    t.string "lease_token", limit: 32
    t.datetime "leased_until"
    t.datetime "resolved_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.check_constraint "((state)::text = ANY ((ARRAY['pending'::character varying, 'released'::character varying, 'retained'::character varying, 'failed'::character varying])::text[]))", name: "external_media_gc_intents_state_check"
    t.check_constraint "((target_type)::text = ANY ((ARRAY['media_attachment'::character varying, 'external_media_asset'::character varying])::text[]))", name: "external_media_gc_intents_target_check"
    t.check_constraint "(((target_type)::text = 'external_media_asset'::text) AND ((reason)::text = ANY ((ARRAY['projection_purge'::character varying, 'asset_unreferenced'::character varying, 'generation_replaced'::character varying])::text[]))) OR (((target_type)::text = 'media_attachment'::text) AND ((reason)::text = ANY ((ARRAY['projection_purge'::character varying, 'attachment_replaced'::character varying])::text[])) AND (owner_account_id IS NOT NULL) AND (captured_status_id IS NOT NULL) AND (source_attachment_id IS NOT NULL) AND (captured_projection_id IS NOT NULL))", name: "external_media_gc_intents_reason_check"
  end

  # MediaGc::Plan inserts with ON CONFLICT (target_type, target_id) WHERE state = 'pending'.
  # Keep this predicate. Do not replace these statements with a db:schema:dump.
  execute <<~SQL
    CREATE UNIQUE INDEX IF NOT EXISTS index_ext_media_gc_open_target
    ON external_media_gc_intents (target_type, target_id)
    WHERE state = 'pending'
  SQL

  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_ext_media_gc_intents_on_due
    ON external_media_gc_intents (available_at, id)
    WHERE state = 'pending'
  SQL

  create_table "external_media_gc_proofs", force: :cascade do |t|
    t.bigint "source_attachment_id", null: false
    t.bigint "media_attachment_id", null: false
    t.bigint "external_status_projection_id", null: false
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["source_attachment_id"], name: "index_ext_media_gc_proofs_on_link", unique: true
  end

  create_table "external_media_gc_asset_rechecks", force: :cascade do |t|
    t.bigint "external_media_asset_id", null: false
    t.string "reason", limit: 32, null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.bigint "external_subscription_deletion_id"
    t.datetime "available_at", null: false
    t.string "last_error_code", limit: 64
    t.datetime "resolved_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.check_constraint "(reason)::text = ANY ((ARRAY['projection_purge'::character varying, 'asset_unreferenced'::character varying, 'generation_replaced'::character varying])::text[])", name: "external_media_gc_asset_rechecks_reason_check"
    t.check_constraint "(state)::text = ANY ((ARRAY['pending'::character varying, 'done'::character varying])::text[])", name: "external_media_gc_asset_rechecks_state_check"
  end

  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_ext_media_gc_rechecks_on_due
    ON external_media_gc_asset_rechecks (available_at, id)
    WHERE state = 'pending'
  SQL

  create_table "external_media_repoint_stages", force: :cascade do |t|
    t.bigint "media_attachment_id", null: false
    t.bigint "external_media_asset_id"
    t.bigint "external_status_projection_id"
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.datetime "lease_until", precision: 6, null: false
    t.string "state", limit: 16, default: "pending", null: false
    t.datetime "available_at", precision: 6, null: false
    t.integer "attempt_count", default: 0, null: false
    t.string "failure_code", limit: 64
    t.string "claim_token", limit: 32
    t.datetime "claimed_until", precision: 6
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_status_projection_id", "external_media_asset_id"], name: "index_ext_media_repoint_stages_on_projection"
    t.index ["lease_until", "id"], name: "index_ext_media_repoint_stages_on_lease"
    t.index ["media_attachment_id"], name: "index_ext_media_repoint_stages_on_attachment", unique: true
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'retained'::character varying]::text[])", name: "external_media_repoint_stages_state_check"
  end

  # Due sweep. A retained or backed-off row is not in this index. Keep the
  # predicate. db:schema:dump may fold it into t.index and drop the WHERE.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_ext_media_repoint_stages_on_due
    ON external_media_repoint_stages (available_at, id)
    WHERE state = 'pending'
  SQL

  create_table "external_oauth_attempts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", limit: 64, default: "bluesky", null: false
    t.string "state_digest", limit: 64, null: false
    t.string "browser_binding_digest", limit: 64, null: false
    t.string "input_kind", limit: 32, null: false
    t.string "login_hint", limit: 512
    t.string "intended_subject", limit: 2048
    t.string "issuer", limit: 512, null: false
    t.string "resource_origin", limit: 512
    t.string "authorization_endpoint", limit: 512, null: false
    t.string "token_endpoint", limit: 512, null: false
    t.string "par_endpoint", limit: 512, null: false
    t.string "revocation_endpoint", limit: 512
    t.string "redirect_uri", limit: 512, null: false
    t.string "requested_scopes", limit: 1024, null: false
    t.string "dpop_nonce", limit: 512
    t.string "binding_id", limit: 36, null: false
    t.text "encrypted_secrets", null: false
    t.string "encryption_key_id", limit: 32, null: false
    t.string "client_key_id", limit: 128, null: false
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["state_digest"], name: "index_external_oauth_attempts_on_state_digest", unique: true
    t.index ["user_id"], name: "index_external_oauth_attempts_on_user_id"
    t.index ["expires_at"], name: "index_external_oauth_attempts_on_open_expires_at", where: "(consumed_at IS NULL)"
    t.index ["created_at", "consumed_at"], name: "index_external_oauth_attempts_on_consumed_age", where: "(consumed_at IS NOT NULL)"
  end

  create_table "external_projection_attachments", force: :cascade do |t|
    t.bigint "external_status_projection_id", null: false
    t.bigint "external_media_asset_id", null: false
    t.bigint "media_attachment_id", null: false
    t.integer "position", default: 0, null: false
    t.string "kind", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_media_asset_id"], name: "index_ext_proj_attachments_on_asset"
    t.index ["external_status_projection_id", "external_media_asset_id"], name: "index_ext_proj_attachments_on_proj_and_asset", unique: true
    t.index ["media_attachment_id"], name: "index_ext_proj_attachments_on_media_attachment", unique: true
  end

  create_table "external_projection_failures", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "external_subscription_id", null: false
    t.bigint "external_resource_id", null: false
    t.string "error_code", null: false
    t.integer "attempt_count", default: 0, null: false
    t.datetime "next_attempt_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_subscription_id"], name: "index_external_projection_failures_on_subscription"
    t.index ["user_id", "external_resource_id"], name: "index_external_projection_failures_on_user_and_resource", unique: true
    t.index ["user_id"], name: "index_external_projection_failures_on_user_id"
  end

  create_table "external_projection_link_boost_states", primary_key: ["user_id", "projection_status_id"], force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "projection_status_id", null: false
    t.bigint "revision", null: false
    t.bigint "notified_revision", default: 0, null: false
    t.datetime "next_notify_at"
    t.boolean "reblogged", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["projection_status_id"], name: "index_link_boost_states_on_projection_status"
    t.check_constraint "((notified_revision >= 0) AND (notified_revision <= revision))", name: "link_boost_states_notified_check"
    t.check_constraint "revision >= 1", name: "link_boost_states_revision_check"
  end

  # Outbox scan. NULLS FIRST matches the scheduler order. db:schema:dump may
  # not keep that clause. Do not replace this statement with a t.index.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_link_boost_states_on_unnotified
    ON external_projection_link_boost_states (next_notify_at ASC NULLS FIRST, updated_at ASC)
    WHERE revision > notified_revision
  SQL

  create_table "external_projection_link_boosts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id", null: false
    t.bigint "link_reference_id", null: false
    t.bigint "external_status_projection_id"
    t.bigint "projection_status_id", null: false
    t.bigint "reference_status_id"
    t.bigint "wrapper_status_id"
    t.string "visibility", null: false
    t.integer "generation", null: false
    t.integer "policy_revision", null: false
    t.string "state", default: "active", null: false
    t.string "ended_reason"
    t.datetime "announced_at"
    t.datetime "announce_enqueued_at"
    t.datetime "next_announce_at"
    t.datetime "undone_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "removal_acknowledged_at"
    t.datetime "removal_next_attempt_at"
    t.datetime "removal_lease_until"
    t.string "removal_lease_token", limit: 32
    t.index ["id"], name: "index_link_boosts_on_orphaned", where: "(((state)::text = 'active'::text) AND (external_status_projection_id IS NULL))"
    t.index ["link_reference_id", "generation"], name: "index_link_boosts_on_generation", unique: true
    t.index ["reference_status_id"], name: "index_link_boosts_on_reference", where: "(reference_status_id IS NOT NULL)"
    t.index ["updated_at"], name: "index_link_boosts_on_pending_removal", where: "(((state)::text = 'undone'::text) AND (wrapper_status_id IS NOT NULL) AND (removal_acknowledged_at IS NULL))"
    t.index ["user_id", "projection_status_id"], name: "index_link_boosts_on_active_share", unique: true, where: "((state)::text = 'active'::text)"
    t.index ["user_id"], name: "index_link_boosts_on_user_id"
    t.index ["wrapper_status_id"], name: "index_link_boosts_on_wrapper", unique: true, where: "(wrapper_status_id IS NOT NULL)"
    t.check_constraint "((state)::text <> 'active'::text) OR (wrapper_status_id IS NOT NULL)", name: "link_boosts_active_requires_wrapper"
    t.check_constraint "((state)::text <> 'undone'::text) OR (undone_at IS NOT NULL)", name: "link_boosts_undone_requires_time"
    t.check_constraint "((state)::text = 'undone'::text) OR (ended_reason IS NULL)", name: "link_boosts_reason_requires_end"
    t.check_constraint "(announce_enqueued_at IS NULL) OR (announced_at IS NOT NULL)", name: "link_boosts_enqueued_requires_announce"
    t.check_constraint "(state)::text = ANY ((ARRAY['active'::character varying, 'undone'::character varying])::text[])", name: "link_boosts_state_check"
    t.check_constraint "(visibility)::text = ANY ((ARRAY['public'::character varying, 'unlisted'::character varying])::text[])", name: "link_boosts_visibility_check"
    t.check_constraint "generation >= 1", name: "link_boosts_generation_check"
  end

  # Partial unannounced scan. NULLS FIRST matches the scheduler order.
  # db:schema:dump may not keep that clause. Do not replace this statement
  # with a t.index on the same columns.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_link_boosts_on_unannounced
    ON external_projection_link_boosts (next_announce_at ASC NULLS FIRST, id)
    WHERE announce_enqueued_at IS NULL
      AND state = 'active'
      AND wrapper_status_id IS NOT NULL
  SQL

  create_table "external_projection_link_references", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id", null: false
    t.bigint "external_status_projection_id"
    t.bigint "projection_status_id", null: false
    t.bigint "reference_status_id"
    t.string "visibility", null: false
    t.text "canonical_url", null: false
    t.text "resource_revision"
    t.integer "policy_revision", null: false
    t.string "state", default: "active", null: false
    t.datetime "superseded_at"
    t.datetime "published_at"
    t.datetime "next_recovery_at"
    t.string "reference_digest", limit: 64
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["reference_status_id"], name: "index_link_refs_on_reference_status", unique: true, where: "(reference_status_id IS NOT NULL)"
    t.index ["user_id"], name: "index_link_refs_on_user_id"
    t.index ["user_id", "external_status_projection_id", "visibility", "canonical_url"], name: "index_link_refs_on_active_identity", unique: true, where: "((state)::text = 'active'::text) AND (external_status_projection_id IS NOT NULL)"
    t.check_constraint "canonical_url ~ '^https?://'", name: "link_refs_canonical_url_check"
    t.check_constraint "state <> 'active' OR reference_status_id IS NOT NULL", name: "link_refs_active_requires_status"
    t.check_constraint "state <> 'superseded' OR superseded_at IS NOT NULL", name: "link_refs_superseded_requires_time"
    t.check_constraint "state IN ('active', 'superseded', 'broken')", name: "link_refs_state_check"
    t.check_constraint "visibility IN ('public', 'unlisted')", name: "link_refs_visibility_check"
  end

  # Partial recovery index. NULLS FIRST matches the scheduler order.
  # db:schema:dump does not keep that clause. Do not replace this statement
  # with a t.index on the same columns.
  execute <<~SQL
    CREATE INDEX IF NOT EXISTS index_link_refs_on_unpublished_recovery
    ON external_projection_link_references (next_recovery_at ASC NULLS FIRST, id)
    WHERE published_at IS NULL
      AND state IN ('active', 'superseded')
      AND reference_status_id IS NOT NULL
  SQL

  create_table "external_projection_suppressions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "external_resource_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["user_id", "external_resource_id"], name: "index_external_projection_suppressions_on_user_and_resource", unique: true
    t.index ["user_id"], name: "index_external_projection_suppressions_on_user_id"
  end

  create_table "external_resources", force: :cascade do |t|
    t.bigint "external_source_id", null: false
    t.bigint "external_actor_id"
    t.string "protocol", null: false
    t.text "canonical_key", null: false
    t.text "revision"
    t.text "canonical_url"
    t.text "title"
    t.text "body"
    t.text "byline"
    t.string "body_digest"
    t.datetime "published_at"
    t.datetime "source_deleted_at"
    t.boolean "truncated", default: false, null: false
    t.datetime "fetched_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.text "media_revision"
    t.jsonb "media_candidates", default: [], null: false
    t.jsonb "keywords", default: [], null: false
    t.index ["external_actor_id"], name: "index_external_resources_on_external_actor_id"
    t.index ["external_source_id", "published_at"], name: "index_external_resources_on_source_and_published_at"
    t.index ["id", "external_source_id"], name: "index_external_resources_on_id_and_source", unique: true
    t.index ["protocol", "canonical_key"], name: "index_external_resources_on_protocol_and_canonical_key", unique: true
    t.check_constraint "(protocol)::text = ANY ((ARRAY['rss'::character varying, 'atom'::character varying])::text[])", name: "external_resources_protocol_check"
  end

  create_table "external_sources", force: :cascade do |t|
    t.string "protocol", null: false
    t.text "canonical_key", null: false
    t.text "etag"
    t.text "last_modified"
    t.datetime "fetched_at"
    t.datetime "checked_at"
    t.text "title"
    t.text "site_url"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.string "icon_file_name"
    t.string "icon_content_type"
    t.bigint "icon_file_size"
    t.datetime "icon_updated_at"
    t.string "icon_fingerprint"
    t.text "icon_remote_url"
    t.string "icon_origin"
    t.text "icon_etag"
    t.text "icon_last_modified"
    t.jsonb "icon_hints"
    t.datetime "icon_checked_at"
    t.datetime "icon_next_check_at"
    t.integer "icon_failure_count", default: 0, null: false
    t.string "icon_error_code"
    t.index ["canonical_key"], name: "index_external_sources_on_canonical_key"
    t.index ["protocol", "canonical_key"], name: "index_external_sources_on_protocol_and_canonical_key", unique: true
    t.check_constraint "(protocol)::text = ANY ((ARRAY['rss'::character varying, 'atom'::character varying])::text[])", name: "external_sources_protocol_check"
  end

  create_table "external_status_projections", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "account_id", null: false
    t.bigint "external_source_id", null: false
    t.bigint "external_subscription_id", null: false
    t.bigint "external_resource_id", null: false
    t.bigint "status_id", null: false
    t.text "last_seen_revision"
    t.boolean "source_deleted", default: false, null: false
    t.bigint "content_generation", default: 0, null: false
    t.bigint "streamed_content_generation"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.text "last_seen_media_revision"
    t.index ["account_id"], name: "index_external_status_projections_on_account_id"
    t.index ["external_subscription_id"], name: "index_external_status_projections_on_subscription"
    t.index ["status_id"], name: "index_external_status_projections_on_status_id", unique: true
    t.index ["user_id", "external_resource_id"], name: "index_external_status_projections_on_user_and_resource", unique: true
    t.index ["user_id"], name: "index_external_status_projections_on_user_id"
  end

  create_table "external_subscription_deletions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "external_subscription_id", null: false
    t.bigint "external_source_id", null: false
    t.string "state", default: "queued", null: false
    t.bigint "total_count"
    t.bigint "deleted_count", default: 0, null: false
    t.jsonb "route_targets", default: [], null: false
    t.integer "attempt_count", default: 0, null: false
    t.string "last_error_code"
    t.datetime "next_run_at"
    t.datetime "requested_at", null: false
    t.datetime "started_at"
    t.datetime "last_progress_at"
    t.datetime "finished_at"
    t.datetime "control_enqueued_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_subscription_id"], name: "index_external_subscription_deletions_on_subscription", unique: true
    t.index ["finished_at"], name: "index_external_subscription_deletions_on_completed", where: "((state)::text = 'completed'::text)"
    t.index ["next_run_at"], name: "index_external_subscription_deletions_on_pending", where: "((state)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying, 'failed'::character varying])::text[]))"
    t.index ["user_id", "id"], name: "index_external_subscription_deletions_on_user"
    t.check_constraint "(state)::text = ANY ((ARRAY['queued'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying])::text[])", name: "external_subscription_deletions_state_check"
  end

  create_table "external_subscription_deletion_effects", force: :cascade do |t|
    t.bigint "external_subscription_deletion_id", null: false
    t.bigint "status_id", null: false
    t.jsonb "destinations"
    t.datetime "cache_cleared_at"
    t.datetime "search_cleared_at"
    t.datetime "stream_enqueued_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["external_subscription_deletion_id", "status_id"], name: "index_deletion_effects_on_deletion_and_status", unique: true
  end

  create_table "external_subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "external_source_id", null: false
    t.string "state", default: "active", null: false
    t.string "last_error_code"
    t.datetime "last_error_at"
    t.datetime "checked_at"
    t.datetime "next_retry_at"
    t.integer "retry_count", default: 0, null: false
    t.integer "failed_item_count", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "feed_routes_revision", default: 0, null: false
    t.boolean "media_sensitive", default: false, null: false
    t.boolean "cw_enabled", default: false, null: false
    t.bigint "presentation_revision", default: 0, null: false
    t.bigint "presentation_applied_revision", default: 0, null: false
    t.string "presentation_error"
    t.datetime "presentation_lease_until"
    t.string "presentation_lease_token"
    t.index ["external_source_id"], name: "index_external_subscriptions_on_external_source_id"
    t.index ["id", "user_id"], name: "index_external_subscriptions_on_id_and_user", unique: true
    t.index ["id", "user_id", "external_source_id"], name: "index_external_subscriptions_on_id_user_and_source", unique: true
    t.index ["user_id", "external_source_id"], name: "index_external_subscriptions_on_user_and_source", unique: true
    t.index ["user_id"], name: "index_external_subscriptions_on_user_id"
    t.check_constraint "(state)::text = ANY ((ARRAY['active'::character varying, 'paused'::character varying, 'error'::character varying, 'deleting'::character varying])::text[])", name: "external_subscriptions_state_check"
  end

  create_table "favourite_domains", force: :cascade do |t|
    t.bigint "account_id"
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_favourite_domains_on_account_id"
  end

  create_table "favourite_tags", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "tag_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_favourite_tags_on_account_id"
    t.index ["tag_id"], name: "index_favourite_tags_on_tag_id"
  end

  create_table "favourites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.index ["account_id", "id"], name: "index_favourites_on_account_id_and_id"
    t.index ["account_id", "status_id"], name: "index_favourites_on_account_id_and_status_id", unique: true
    t.index ["status_id"], name: "index_favourites_on_status_id"
  end

  create_table "featured_tags", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "tag_id"
    t.bigint "statuses_count", default: 0, null: false
    t.datetime "last_status_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["account_id"], name: "index_featured_tags_on_account_id"
    t.index ["tag_id"], name: "index_featured_tags_on_tag_id"
  end

  create_table "follow_import_batches", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.bigint "import_id"
    t.datetime "imported_at", null: false
    t.integer "mode", default: 0, null: false
    t.integer "target_count", default: 0, null: false
    t.integer "resolved_target_count", default: 0, null: false
    t.integer "unresolved_target_count", default: 0, null: false
    t.bigint "account_age_seconds"
    t.integer "migration_evidence", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "dispatch_owner", default: 0, null: false
    t.integer "dispatch_cohort", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.integer "preflight_state", default: 1, null: false
    t.index ["import_id"], name: "index_follow_import_batches_on_import_id", unique: true, where: "(import_id IS NOT NULL)"
    t.index ["subject_id", "imported_at"], name: "index_follow_import_batches_on_subject_and_imported_at"
  end

  create_table "follow_import_targets", force: :cascade do |t|
    t.bigint "batch_id", null: false
    t.bigint "target_subject_id"
    t.string "target_key_hash"
    t.integer "position"
    t.jsonb "prior_relationship_state"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.integer "state", default: 0, null: false
    t.string "follow_request_uri"
    t.datetime "queued_at"
    t.datetime "delivered_at"
    t.datetime "response_deadline_at"
    t.datetime "completed_at"
    t.integer "delivery_attempts", default: 0, null: false
    t.string "failure_code"
    t.string "destination_domain"
    t.index ["batch_id", "state"], name: "index_follow_import_targets_on_batch_and_state"
    t.index ["batch_id"], name: "index_follow_import_targets_on_pending_batch_id", where: "(state = 0)"
    t.index ["batch_id", "position", "id"], name: "index_follow_import_targets_on_pending_batch_position", where: "(state = 0)"
    t.index ["destination_domain"], name: "index_follow_import_targets_on_destination_domain", where: "(destination_domain IS NOT NULL)"
    t.index ["batch_id", "target_subject_id"], name: "index_follow_import_targets_on_batch_and_target"
    t.index ["follow_request_uri"], name: "index_follow_import_targets_on_follow_request_uri", unique: true, where: "(follow_request_uri IS NOT NULL)"
    t.index ["target_key_hash"], name: "index_follow_import_targets_on_target_key_hash", where: "(target_key_hash IS NOT NULL)"
    t.index ["target_subject_id"], name: "index_follow_import_targets_on_target_subject", where: "(target_subject_id IS NOT NULL)"
  end

  create_table "follow_import_dispatch_leases", force: :cascade do |t|
    t.string "owner_token"
    t.bigint "fencing_generation", default: 0, null: false
    t.datetime "expires_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "follow_import_dispatch_observations", force: :cascade do |t|
    t.bigint "batch_id"
    t.datetime "observed_at", null: false
    t.integer "candidate_count"
    t.integer "claimed_count"
    t.integer "pending_count"
    t.jsonb "load_snapshot"
    t.jsonb "execution_policy", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "batch_pending_before"
    t.integer "batch_pending_after"
    t.integer "global_pending_count"
    t.integer "active_batch_count"
    t.string "pass_error_class"
    t.boolean "local_load_enforcement_enabled"
    t.string "local_load_state"
    t.integer "local_load_budget_percent"
    t.integer "local_load_recommended_budget"
    t.integer "effective_execution_budget"
    t.boolean "local_load_would_skip"
    t.boolean "local_load_measurement_complete"
    t.integer "local_load_profile_version"
    t.string "local_load_profile_source"
    t.boolean "local_load_fallback_used"
    t.boolean "load_deferred"
    t.jsonb "local_load_decision"
    t.index ["batch_id", "observed_at"], name: "index_fi_dispatch_observations_on_batch_and_observed_at"
    t.index ["observed_at"], name: "index_fi_dispatch_observations_on_observed_at"
  end

  create_table "follow_import_dispatch_tick_observations", force: :cascade do |t|
    t.datetime "observed_at", null: false
    t.string "tick_id", null: false
    t.string "scheduler_mode", null: false
    t.boolean "lease_acquired", null: false
    t.string "outcome", null: false
    t.integer "global_pending_count"
    t.integer "active_batch_count"
    t.integer "historical_pending_count"
    t.integer "operational_pending_count"
    t.integer "planning_pending_count"
    t.integer "historical_active_batch_count"
    t.integer "operational_active_batch_count"
    t.integer "planning_active_batch_count"
    t.integer "claimed_count", default: 0, null: false
    t.integer "planned_count"
    t.integer "executable_owner_count"
    t.integer "executable_batch_count"
    t.integer "unique_destination_count"
    t.integer "skipped_missing_owner_count"
    t.integer "planned_owner_count"
    t.integer "planned_batch_count"
    t.string "fairness_state_source"
    t.string "local_load_state"
    t.integer "local_load_budget_percent"
    t.integer "local_load_recommended_budget"
    t.integer "effective_shadow_plan_budget"
    t.boolean "local_load_would_skip"
    t.boolean "local_load_measurement_complete"
    t.integer "local_load_profile_version"
    t.string "local_load_profile_source"
    t.boolean "local_load_fallback_used"
    t.integer "global_base_budget"
    t.integer "effective_global_budget"
    t.integer "skipped_stale_count"
    t.integer "skipped_unrecoverable_count"
    t.integer "skipped_wrong_owner_count"
    t.boolean "remote_admission_enabled"
    t.boolean "remote_admission_configured"
    t.integer "remote_profile_version"
    t.integer "skipped_destination_cap_count"
    t.integer "skipped_origin_cap_count"
    t.integer "skipped_unavailable_count"
    t.integer "skipped_retry_after_count"
    t.integer "skipped_recent_429_count"
    t.integer "scanned_target_count"
    t.integer "windows_scanned"
    t.integer "scan_budget_exhausted_count"
    t.integer "mapped_origin_candidate_count"
    t.boolean "adaptive_remote_shadow_enabled"
    t.boolean "adaptive_remote_configured"
    t.integer "adaptive_profile_version"
    t.integer "adaptive_shadow_evaluated_current_claim_count"
    t.integer "adaptive_shadow_would_block_current_claim_count"
    t.integer "adaptive_shadow_destination_would_block_count"
    t.integer "adaptive_shadow_origin_would_block_count"
    t.integer "adaptive_runtime_unavailable_count"
    t.integer "adaptive_destination_cap_min"
    t.integer "adaptive_destination_cap_max"
    t.integer "adaptive_origin_cap_min"
    t.integer "adaptive_origin_cap_max"
    t.jsonb "load_snapshot"
    t.jsonb "execution_config"
    t.string "error_class"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["observed_at"], name: "index_fi_dispatch_tick_observations_on_observed_at"
    t.index ["tick_id"], name: "index_fi_dispatch_tick_observations_on_tick_id"
  end

  create_table "follow_import_transport_observations", force: :cascade do |t|
    t.bigint "batch_id"
    t.bigint "target_id"
    t.string "phase", null: false
    t.string "destination_domain"
    t.string "endpoint_origin"
    t.string "sidekiq_queue"
    t.string "sidekiq_job_id"
    t.datetime "started_at", null: false
    t.datetime "finished_at", null: false
    t.integer "duration_ms"
    t.string "outcome", null: false
    t.integer "http_status"
    t.integer "retry_after_seconds"
    t.string "error_class"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "enqueued_at"
    t.datetime "request_started_at"
    t.datetime "request_finished_at"
    t.integer "queue_wait_ms"
    t.integer "request_duration_ms"
    t.index ["batch_id"], name: "index_fi_transport_observations_on_batch_id"
    t.index ["phase", "destination_domain", "started_at"], name: "index_fi_transport_observations_on_phase_domain_started"
    t.index ["phase", "endpoint_origin", "started_at"], name: "index_fi_transport_observations_on_phase_origin_started"
    t.index ["started_at"], name: "index_fi_transport_observations_on_started_at"
    t.index ["target_id"], name: "index_fi_transport_observations_on_target_id"
  end

  create_table "follow_recommendation_suppressions", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["account_id"], name: "index_follow_recommendation_suppressions_on_account_id", unique: true
  end

  create_table "follow_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "target_account_id", null: false
    t.boolean "show_reblogs", default: true, null: false
    t.string "uri"
    t.boolean "notify", default: false, null: false
    t.boolean "notify_reblogs", default: false, null: false
    t.boolean "delivery", default: true, null: false
    t.string "languages", array: true
    t.index ["account_id", "target_account_id"], name: "index_follow_requests_on_account_id_and_target_account_id", unique: true
  end

  create_table "follow_tags", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "tag_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "list_id"
    t.boolean "media_only", default: false, null: false
    t.index ["account_id"], name: "index_follow_tags_on_account_id"
    t.index ["list_id"], name: "index_follow_tags_on_list_id"
    t.index ["tag_id"], name: "index_follow_tags_on_tag_id"
  end

  create_table "follows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "target_account_id", null: false
    t.boolean "show_reblogs", default: true, null: false
    t.string "uri"
    t.boolean "notify", default: false, null: false
    t.boolean "notify_reblogs", default: false, null: false
    t.boolean "delivery", default: true, null: false
    t.string "languages", array: true
    t.index ["account_id", "target_account_id"], name: "index_follows_on_account_id_and_target_account_id", unique: true
    t.index ["target_account_id"], name: "index_follows_on_target_account_id"
    t.index ["target_account_id", "id"], name: "index_follows_on_reblog_notifications", where: "notify_reblogs"
  end

  create_table "generators", force: :cascade do |t|
    t.string "uri", default: "", null: false
    t.integer "type", default: 0, null: false
    t.string "name", default: "", null: false
    t.string "website"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "group_affiliations", force: :cascade do |t|
    t.bigint "group_account_id", null: false
    t.string "subject_uri", null: false
    t.string "relationship", null: false
    t.string "affiliation_uri"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["group_account_id", "subject_uri", "relationship"], name: "index_group_affiliations_on_identity", unique: true
    t.index ["group_account_id"], name: "index_group_affiliations_on_group_account_id"
  end

  create_table "identities", force: :cascade do |t|
    t.string "provider", default: "", null: false
    t.string "uid", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "imports", force: :cascade do |t|
    t.integer "type", null: false
    t.boolean "approved", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "data_file_name"
    t.string "data_content_type"
    t.integer "data_file_size"
    t.datetime "data_updated_at"
    t.bigint "account_id", null: false
    t.boolean "overwrite", default: false, null: false
    t.integer "follow_import_pipeline_version"
  end

  create_table "invites", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "code", default: "", null: false
    t.datetime "expires_at"
    t.integer "max_uses"
    t.integer "uses", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "autofollow", default: false, null: false
    t.text "comment"
    t.index ["code"], name: "index_invites_on_code", unique: true
    t.index ["user_id"], name: "index_invites_on_user_id"
  end

  create_table "ip_blocks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "expires_at"
    t.inet "ip", default: "0.0.0.0", null: false
    t.integer "severity", default: 0, null: false
    t.text "comment", default: "", null: false
    t.index ["ip"], name: "index_ip_blocks_on_ip", unique: true
  end

  create_table "keyword_subscribes", force: :cascade do |t|
    t.bigint "account_id"
    t.string "keyword", null: false
    t.boolean "ignorecase", default: true
    t.boolean "regexp", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "name", default: "", null: false
    t.boolean "ignore_block", default: false
    t.boolean "disabled", default: false
    t.string "exclude_keyword", default: "", null: false
    t.bigint "list_id"
    t.boolean "media_only", default: false, null: false
    t.boolean "match_hashtags", default: false, null: false
    t.boolean "match_urls", default: false, null: false
    t.index ["account_id"], name: "index_keyword_subscribes_on_account_id"
    t.index ["list_id"], name: "index_keyword_subscribes_on_list_id"
  end

  create_table "list_accounts", force: :cascade do |t|
    t.bigint "list_id", null: false
    t.bigint "account_id", null: false
    t.bigint "follow_id"
    t.index ["account_id", "list_id"], name: "index_list_accounts_on_account_id_and_list_id", unique: true
    t.index ["follow_id"], name: "index_list_accounts_on_follow_id"
    t.index ["list_id", "account_id"], name: "index_list_accounts_on_list_id_and_account_id"
  end

  create_table "lists", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.string "title", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "replies_policy", default: 0, null: false
    t.boolean "favourite", default: false, null: false
    t.index ["account_id"], name: "index_lists_on_account_id"
  end

  create_table "login_activities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "authentication_method"
    t.string "provider"
    t.boolean "success"
    t.string "failure_reason"
    t.inet "ip"
    t.string "user_agent"
    t.datetime "created_at"
    t.index ["user_id"], name: "index_login_activities_on_user_id"
  end

  create_table "markers", force: :cascade do |t|
    t.bigint "user_id"
    t.string "timeline", default: "", null: false
    t.bigint "last_read_id", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "timeline"], name: "index_markers_on_user_id_and_timeline", unique: true
  end

  create_table "media_attachments", id: :bigint, default: -> { "timestamp_id('media_attachments'::text)" }, force: :cascade do |t|
    t.bigint "status_id"
    t.string "file_file_name"
    t.string "file_content_type"
    t.integer "file_file_size"
    t.datetime "file_updated_at"
    t.string "remote_url", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "shortcode"
    t.integer "type", default: 0, null: false
    t.json "file_meta"
    t.bigint "account_id"
    t.text "description"
    t.bigint "scheduled_status_id"
    t.string "blurhash"
    t.integer "processing"
    t.integer "file_storage_schema_version"
    t.string "thumbnail_file_name"
    t.string "thumbnail_content_type"
    t.integer "thumbnail_file_size"
    t.datetime "thumbnail_updated_at"
    t.string "thumbnail_remote_url"
    t.string "thumbhash"
    t.index ["account_id", "status_id"], name: "index_media_attachments_on_account_id_and_status_id", order: { status_id: :desc }
    t.index ["scheduled_status_id"], name: "index_media_attachments_on_scheduled_status_id"
    t.index ["shortcode"], name: "index_media_attachments_on_shortcode", unique: true
    t.index ["status_id"], name: "index_media_attachments_on_status_id"
  end

  create_table "mentions", force: :cascade do |t|
    t.bigint "status_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id"
    t.boolean "silent", default: false, null: false
    t.index ["account_id", "status_id"], name: "index_mentions_on_account_id_and_status_id", unique: true
    t.index ["status_id"], name: "index_mentions_on_status_id"
  end

  create_table "moderation_actions", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.integer "action_type", null: false
    t.datetime "performed_at", null: false
    t.bigint "moderator_account_id"
    t.string "reason_code"
    t.bigint "evidence_snapshot_id"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["action_type", "performed_at"], name: "index_moderation_actions_on_type_and_performed"
    t.index ["evidence_snapshot_id"], name: "index_moderation_actions_on_evidence_snapshot", where: "(evidence_snapshot_id IS NOT NULL)"
    t.index ["moderator_account_id"], name: "index_moderation_actions_on_moderator", where: "(moderator_account_id IS NOT NULL)"
    t.index ["subject_id", "performed_at"], name: "index_moderation_actions_on_subject_and_performed"
  end

  create_table "moderation_evidence_snapshots", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.datetime "window_start"
    t.datetime "window_end"
    t.jsonb "summary", default: {}, null: false
    t.jsonb "fingerprint", default: {}, null: false
    t.integer "schema_version", default: 1, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["subject_id", "created_at"], name: "index_mod_evidence_snapshots_on_subject_and_created"
  end

  create_table "moderation_interaction_events", force: :cascade do |t|
    t.bigint "actor_subject_id"
    t.bigint "target_subject_id"
    t.integer "event_type", null: false
    t.bigint "status_id"
    t.string "source_record_type"
    t.bigint "source_record_id"
    t.bigint "import_batch_id"
    t.string "source_event_key"
    t.datetime "occurred_at", null: false
    t.datetime "observed_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["actor_subject_id", "occurred_at"], name: "index_mod_interaction_events_on_actor_and_occurred"
    t.index ["actor_subject_id", "target_subject_id", "occurred_at"], name: "index_mod_interaction_events_on_actor_target_occurred"
    t.index ["event_type", "occurred_at"], name: "index_mod_interaction_events_on_type_and_occurred"
    t.index ["source_event_key"], name: "index_mod_interaction_events_on_source_event_key", unique: true, where: "(source_event_key IS NOT NULL)"
    t.index ["target_subject_id", "occurred_at"], name: "index_mod_interaction_events_on_target_and_occurred"
  end

  create_table "moderation_rejection_events", force: :cascade do |t|
    t.bigint "rejector_subject_id"
    t.bigint "rejected_subject_id"
    t.integer "event_type", null: false
    t.bigint "preceding_interaction_event_id"
    t.string "source_event_key"
    t.datetime "occurred_at", null: false
    t.datetime "observed_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["event_type", "occurred_at"], name: "index_mod_rejection_events_on_type_and_occurred"
    t.index ["preceding_interaction_event_id"], name: "index_mod_rejection_events_on_preceding_event", where: "(preceding_interaction_event_id IS NOT NULL)"
    t.index ["source_event_key"], name: "index_mod_rejection_events_on_source_event_key", unique: true, where: "(source_event_key IS NOT NULL)"
    t.index ["rejected_subject_id", "occurred_at"], name: "index_mod_rejection_events_on_rejected_and_occurred"
    t.index ["rejected_subject_id", "rejector_subject_id", "occurred_at"], name: "index_mod_rejection_events_on_rejected_rejector_occurred"
    t.index ["rejector_subject_id", "occurred_at"], name: "index_mod_rejection_events_on_rejector_and_occurred"
  end

  create_table "moderation_subjects", force: :cascade do |t|
    t.bigint "account_id"
    t.integer "origin", default: 0, null: false
    t.string "domain"
    t.string "actor_uri_hash"
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "deleted_at"
    t.datetime "retention_until"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["account_id"], name: "index_moderation_subjects_on_account_id", unique: true, where: "(account_id IS NOT NULL)"
    t.index ["actor_uri_hash"], name: "index_moderation_subjects_on_actor_uri_hash", where: "(actor_uri_hash IS NOT NULL)"
    t.index ["deleted_at"], name: "index_moderation_subjects_on_deleted_at"
    t.index ["retention_until"], name: "index_moderation_subjects_on_retention_until"
  end

  create_table "mutes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "hide_notifications", default: true, null: false
    t.bigint "account_id", null: false
    t.bigint "target_account_id", null: false
    t.datetime "expires_at"
    t.index ["account_id", "target_account_id"], name: "index_mutes_on_account_id_and_target_account_id", unique: true
    t.index ["target_account_id"], name: "index_mutes_on_target_account_id"
  end

  create_table "nodes", force: :cascade do |t|
    t.string "domain", null: false
    t.jsonb "info"
    t.jsonb "info_override"
    t.jsonb "nodeinfo"
    t.jsonb "instance_data"
    t.string "icon_file_name"
    t.string "icon_content_type"
    t.bigint "icon_file_size"
    t.datetime "icon_updated_at"
    t.string "icon_remote_url"
    t.string "thumbnail_file_name"
    t.string "thumbnail_content_type"
    t.bigint "thumbnail_file_size"
    t.datetime "thumbnail_updated_at"
    t.string "thumbnail_remote_url"
    t.string "blurhash"
    t.datetime "last_fetched_at"
    t.integer "status", default: 0, null: false
    t.string "note", default: "", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.string "thumbhash"
    t.index ["domain"], name: "index_nodes_on_domain", unique: true
    t.index ["info"], name: "index_nodes_on_info", using: :gin
    t.index ["last_fetched_at"], name: "index_nodes_on_last_fetched_at"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "activity_id", null: false
    t.string "activity_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "from_account_id", null: false
    t.string "type"
    t.index ["account_id", "id", "type"], name: "index_notifications_on_account_id_and_id_and_type", order: { id: :desc }
    t.index ["activity_id", "activity_type"], name: "index_notifications_on_activity_id_and_activity_type"
    t.index ["from_account_id"], name: "index_notifications_on_from_account_id"
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "scopes"
    t.bigint "application_id", null: false
    t.bigint "resource_owner_id", null: false
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.string "scopes"
    t.bigint "application_id"
    t.bigint "resource_owner_id"
    t.datetime "last_used_at"
    t.inet "last_used_ip"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.datetime "created_at"
    t.datetime "updated_at"
    t.boolean "superapp", default: false, null: false
    t.string "website"
    t.string "owner_type"
    t.bigint "owner_id"
    t.boolean "confidential", default: true, null: false
    t.index ["owner_id", "owner_type"], name: "index_oauth_applications_on_owner_id_and_owner_type"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "one_time_keys", force: :cascade do |t|
    t.bigint "device_id"
    t.string "key_id", default: "", null: false
    t.text "key", default: "", null: false
    t.text "signature", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["device_id"], name: "index_one_time_keys_on_device_id"
    t.index ["key_id"], name: "index_one_time_keys_on_key_id"
  end

  create_table "pghero_space_stats", force: :cascade do |t|
    t.text "database"
    t.text "schema"
    t.text "relation"
    t.bigint "size"
    t.datetime "captured_at"
    t.index ["database", "captured_at"], name: "index_pghero_space_stats_on_database_and_captured_at"
  end

  create_table "poll_votes", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "poll_id"
    t.integer "choice", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "uri"
    t.index ["account_id"], name: "index_poll_votes_on_account_id"
    t.index ["poll_id"], name: "index_poll_votes_on_poll_id"
  end

  create_table "polls", force: :cascade do |t|
    t.bigint "account_id"
    t.bigint "status_id"
    t.datetime "expires_at"
    t.string "options", default: [], null: false, array: true
    t.bigint "cached_tallies", default: [], null: false, array: true
    t.boolean "multiple", default: false, null: false
    t.boolean "hide_totals", default: false, null: false
    t.bigint "votes_count", default: 0, null: false
    t.datetime "last_fetched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.bigint "voters_count"
    t.index ["account_id"], name: "index_polls_on_account_id"
    t.index ["status_id"], name: "index_polls_on_status_id"
  end

  create_table "posting_identity_delegations", force: :cascade do |t|
    t.bigint "grantor_user_id", null: false
    t.bigint "grantee_user_id", null: false
    t.bigint "posting_account_id", null: false
    t.string "scopes", default: [], null: false, array: true
    t.datetime "expires_at", null: false
    t.datetime "approved_at", null: false
    t.datetime "revoked_at"
    t.datetime "superseded_at"
    t.datetime "last_used_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["grantee_user_id", "grantor_user_id"], name: "index_posting_identity_delegations_one_active_pair", unique: true, where: "((revoked_at IS NULL) AND (superseded_at IS NULL))"
    t.index ["grantee_user_id"], name: "index_posting_identity_delegations_on_grantee_user_id"
    t.index ["grantor_user_id"], name: "index_posting_identity_delegations_on_grantor_user_id"
    t.index ["posting_account_id"], name: "index_posting_identity_delegations_on_posting_account_id"
  end

  create_table "posting_identity_link_requests", force: :cascade do |t|
    t.bigint "requester_user_id", null: false
    t.bigint "target_user_id", null: false
    t.string "token_digest", limit: 64, null: false
    t.string "scopes", default: [], null: false, array: true
    t.datetime "expires_at", null: false
    t.datetime "consumed_at"
    t.datetime "canceled_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "request_allowance_id"
    t.integer "allowance_generation"
    t.index ["request_allowance_id"], name: "index_posting_identity_link_requests_on_allowance_id"
    t.index ["requester_user_id"], name: "index_posting_identity_link_requests_on_requester_user_id"
    t.index ["target_user_id"], name: "index_posting_identity_link_requests_on_target_user_id"
    t.index ["token_digest"], name: "index_posting_identity_link_requests_on_token_digest", unique: true
  end

  create_table "posting_identity_media", force: :cascade do |t|
    t.bigint "grantee_user_id", null: false
    t.bigint "delegation_id", null: false
    t.bigint "posting_account_id", null: false
    t.bigint "media_attachment_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["delegation_id"], name: "index_posting_identity_media_on_delegation_id"
    t.index ["grantee_user_id"], name: "index_posting_identity_media_on_grantee_user_id"
    t.index ["media_attachment_id"], name: "index_posting_identity_media_on_media_attachment_id", unique: true
    t.index ["posting_account_id"], name: "index_posting_identity_media_on_posting_account_id"
  end

  create_table "posting_identity_posts", force: :cascade do |t|
    t.bigint "grantee_user_id", null: false
    t.bigint "delegation_id", null: false
    t.bigint "posting_account_id", null: false
    t.bigint "status_id", null: false
    t.datetime "posted_at", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["delegation_id"], name: "index_posting_identity_posts_on_delegation_id"
    t.index ["grantee_user_id"], name: "index_posting_identity_posts_on_grantee_user_id"
    t.index ["posting_account_id"], name: "index_posting_identity_posts_on_posting_account_id"
    t.index ["status_id"], name: "index_posting_identity_posts_on_status_id", unique: true
  end

  create_table "posting_identity_request_allowances", force: :cascade do |t|
    t.bigint "grantor_user_id", null: false
    t.bigint "requester_user_id", null: false
    t.string "allowed_scopes", default: [], null: false, array: true
    t.datetime "allowed_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.integer "generation", default: 1, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["grantor_user_id", "requester_user_id"], name: "index_posting_identity_request_allowances_on_pair", unique: true
    t.index ["requester_user_id"], name: "index_posting_identity_request_allowances_on_requester_user_id"
  end

  create_table "preview_card_providers", force: :cascade do |t|
    t.string "domain", default: "", null: false
    t.string "icon_file_name"
    t.string "icon_content_type"
    t.bigint "icon_file_size"
    t.datetime "icon_updated_at"
    t.boolean "trendable"
    t.datetime "reviewed_at"
    t.datetime "requested_review_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["domain"], name: "index_preview_card_providers_on_domain", unique: true
  end

  create_table "preview_card_trends", force: :cascade do |t|
    t.bigint "preview_card_id", null: false
    t.float "score", default: 0.0, null: false
    t.integer "rank", default: 0, null: false
    t.boolean "allowed", default: false, null: false
    t.string "language"
    t.index ["preview_card_id"], name: "index_preview_card_trends_on_preview_card_id", unique: true
  end

  create_table "preview_cards", force: :cascade do |t|
    t.string "url", default: "", null: false
    t.string "title", default: "", null: false
    t.string "description", default: "", null: false
    t.string "image_file_name"
    t.string "image_content_type"
    t.integer "image_file_size"
    t.datetime "image_updated_at"
    t.integer "type", default: 0, null: false
    t.text "html", default: "", null: false
    t.string "author_name", default: "", null: false
    t.string "author_url", default: "", null: false
    t.string "provider_name", default: "", null: false
    t.string "provider_url", default: "", null: false
    t.integer "width", default: 0, null: false
    t.integer "height", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "embed_url", default: "", null: false
    t.integer "image_storage_schema_version"
    t.string "blurhash"
    t.string "thumbhash"
    t.string "redirected_url"
    t.string "language"
    t.float "max_score"
    t.datetime "max_score_at"
    t.boolean "trendable"
    t.integer "link_type"
    t.string "image_description", default: "", null: false
    t.datetime "published_at"
    t.index ["url"], name: "index_preview_cards_on_url", unique: true
  end

  create_table "preview_cards_statuses", id: false, force: :cascade do |t|
    t.bigint "preview_card_id", null: false
    t.bigint "status_id", null: false
    t.index ["status_id", "preview_card_id"], name: "index_preview_cards_statuses_on_status_id_and_preview_card_id"
  end

  create_table "push_subscription_blocks", force: :cascade do |t|
    t.string "name", default: "", null: false
    t.string "endpoint", null: false
    t.boolean "enable", default: true, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "redirect_links", force: :cascade do |t|
    t.string "url", null: false
    t.string "redirected_url", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["url"], name: "index_redirect_links_on_url", unique: true
  end

  create_table "relays", force: :cascade do |t|
    t.string "inbox_url", default: "", null: false
    t.string "follow_activity_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "state", default: 0, null: false
  end

  create_table "report_notes", force: :cascade do |t|
    t.text "content", null: false
    t.bigint "report_id", null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_report_notes_on_account_id"
    t.index ["report_id"], name: "index_report_notes_on_report_id"
  end

  create_table "reports", force: :cascade do |t|
    t.bigint "status_ids", default: [], null: false, array: true
    t.text "comment", default: "", null: false
    t.boolean "action_taken", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "account_id", null: false
    t.bigint "action_taken_by_account_id"
    t.bigint "target_account_id", null: false
    t.bigint "assigned_account_id"
    t.string "uri"
    t.boolean "forwarded"
    t.integer "category", default: 0, null: false
    t.bigint "rule_ids", array: true
    t.datetime "action_taken_at"
    t.index ["account_id"], name: "index_reports_on_account_id"
    t.index ["target_account_id"], name: "index_reports_on_target_account_id"
  end

  create_table "rules", force: :cascade do |t|
    t.integer "priority", default: 0, null: false
    t.datetime "deleted_at"
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "hint", default: "", null: false
  end

  create_table "scheduled_statuses", force: :cascade do |t|
    t.bigint "account_id"
    t.datetime "scheduled_at"
    t.jsonb "params"
    t.index ["account_id"], name: "index_scheduled_statuses_on_account_id"
    t.index ["scheduled_at"], name: "index_scheduled_statuses_on_scheduled_at"
  end

  create_table "session_activations", force: :cascade do |t|
    t.string "session_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent", default: "", null: false
    t.inet "ip"
    t.bigint "access_token_id"
    t.bigint "user_id", null: false
    t.bigint "web_push_subscription_id"
    t.index ["access_token_id"], name: "index_session_activations_on_access_token_id"
    t.index ["session_id"], name: "index_session_activations_on_session_id", unique: true
    t.index ["user_id"], name: "index_session_activations_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "var", null: false
    t.text "value"
    t.string "thing_type"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.bigint "thing_id"
    t.index ["thing_type", "thing_id", "var"], name: "index_settings_on_thing_type_and_thing_id_and_var", unique: true
  end

  create_table "site_uploads", force: :cascade do |t|
    t.string "var", default: "", null: false
    t.string "file_file_name"
    t.string "file_content_type"
    t.integer "file_file_size"
    t.datetime "file_updated_at"
    t.json "meta"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "blurhash"
    t.index ["var"], name: "index_site_uploads_on_var", unique: true
  end

  create_table "status_capability_tokens", force: :cascade do |t|
    t.bigint "status_id"
    t.string "token"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status_id"], name: "index_status_capability_tokens_on_status_id"
  end

  create_table "status_edits", force: :cascade do |t|
    t.bigint "status_id", null: false
    t.bigint "account_id"
    t.text "text", default: "", null: false
    t.text "spoiler_text", default: "", null: false
    t.bigint "ordered_media_attachment_ids", array: true
    t.text "media_descriptions", array: true
    t.string "poll_options", array: true
    t.boolean "sensitive"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["account_id"], name: "index_status_edits_on_account_id"
    t.index ["status_id"], name: "index_status_edits_on_status_id"
  end

  create_table "status_expires", force: :cascade do |t|
    t.bigint "status_id", null: false
    t.datetime "expires_at", null: false
    t.integer "action", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["expires_at"], name: "index_status_expires_on_expires_at"
    t.index ["status_id"], name: "index_status_expires_on_status_id", unique: true
  end

  create_table "status_pins", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "status_id", null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["account_id", "status_id"], name: "index_status_pins_on_account_id_and_status_id", unique: true
  end

  create_table "status_references", force: :cascade do |t|
    t.bigint "status_id", null: false
    t.bigint "target_status_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["status_id", "target_status_id"], name: "index_status_references_on_status_id_and_target_status_id", unique: true
  end

  create_table "status_stats", force: :cascade do |t|
    t.bigint "status_id", null: false
    t.bigint "replies_count", default: 0, null: false
    t.bigint "reblogs_count", default: 0, null: false
    t.bigint "favourites_count", default: 0, null: false
    t.bigint "emoji_reactions_count", default: 0, null: false
    t.string "emoji_reactions_cache", default: "", null: false
    t.boolean "emoji_reactions_cache_dirty", default: false, null: false
    t.bigint "status_references_count", default: 0, null: false
    t.bigint "status_referred_by_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status_id"], name: "index_status_stats_on_dirty_emoji_reactions_cache", where: "(emoji_reactions_cache_dirty = true)"
    t.index ["status_id"], name: "index_status_stats_on_status_id", unique: true
  end

  create_table "status_trends", force: :cascade do |t|
    t.bigint "status_id", null: false
    t.bigint "account_id", null: false
    t.float "score", default: 0.0, null: false
    t.integer "rank", default: 0, null: false
    t.boolean "allowed", default: false, null: false
    t.string "language"
    t.index ["account_id"], name: "index_status_trends_on_account_id"
    t.index ["status_id"], name: "index_status_trends_on_status_id", unique: true
  end

  create_table "statuses", id: :bigint, default: -> { "timestamp_id('statuses'::text)" }, force: :cascade do |t|
    t.string "uri"
    t.text "text", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "in_reply_to_id"
    t.bigint "reblog_of_id"
    t.string "url"
    t.boolean "sensitive", default: false, null: false
    t.integer "visibility", default: 0, null: false
    t.text "spoiler_text", default: "", null: false
    t.boolean "reply", default: false, null: false
    t.string "language"
    t.bigint "conversation_id"
    t.boolean "local"
    t.bigint "account_id", null: false
    t.bigint "application_id"
    t.bigint "in_reply_to_account_id"
    t.bigint "poll_id"
    t.datetime "deleted_at"
    t.bigint "quote_id"
    t.datetime "expired_at"
    t.integer "searchability"
    t.bigint "generator_id"
    t.bigint "ordered_media_attachment_ids", array: true
    t.datetime "edited_at"
    t.boolean "trendable"
    t.bigint "audience_account_id"
    t.text "post_title"
    t.string "ap_object_type"
    t.boolean "external_projection"
    t.index ["account_id", "id", "visibility", "updated_at"], name: "index_statuses_20210710", order: { id: :desc }, where: "((deleted_at IS NULL) AND (expired_at IS NULL))"
    t.index ["account_id", "id"], name: "index_statuses_private_searchable", order: { id: :desc }, where: "((deleted_at IS NULL) AND (expired_at IS NULL) AND (reblog_of_id IS NULL) AND (searchability = ANY (ARRAY[0, 1, 2])))"
    t.index ["audience_account_id"], name: "index_statuses_on_audience_account_id"
    t.index ["id", "account_id"], name: "index_statuses_local_20190824", order: { id: :desc }, where: "((local OR (uri IS NULL)) AND (deleted_at IS NULL) AND (visibility = 0) AND (reblog_of_id IS NULL) AND ((NOT reply) OR (in_reply_to_account_id = account_id)))"
    t.index ["id", "account_id"], name: "index_statuses_public_20200119", order: { id: :desc }, where: "((deleted_at IS NULL) AND (visibility = 0) AND (reblog_of_id IS NULL) AND ((NOT reply) OR (in_reply_to_account_id = account_id)))"
    t.index ["account_id", "id"], name: "index_statuses_personal_timeline", order: :desc, where: "((visibility = 200) AND (deleted_at IS NULL) AND (reblog_of_id IS NULL))"
    t.index ["in_reply_to_account_id"], name: "index_statuses_on_in_reply_to_account_id"
    t.index ["in_reply_to_id"], name: "index_statuses_on_in_reply_to_id"
    t.index ["quote_id"], name: "index_statuses_on_quote_id"
    t.index ["reblog_of_id", "account_id"], name: "index_statuses_on_reblog_of_id_and_account_id"
    t.index ["uri"], name: "index_statuses_on_uri", unique: true
    t.index ["url"], name: "index_statuses_on_url"
    t.check_constraint "((ap_object_type IS NULL) OR ((ap_object_type)::text = ANY ((ARRAY['note'::character varying, 'page'::character varying])::text[]))) AND ((post_title IS NULL) OR (((char_length(post_title) >= 1) AND (char_length(post_title) <= 100)) AND (post_title !~ '[[:cntrl:]]'::text) AND (btrim(post_title) <> ''::text))) AND (((ap_object_type)::text IS DISTINCT FROM 'page'::text) OR (post_title IS NOT NULL))", name: "statuses_post_title_shape"
  end

  create_table "statuses_tags", id: false, force: :cascade do |t|
    t.bigint "status_id", null: false
    t.bigint "tag_id", null: false
    t.index ["status_id"], name: "index_statuses_tags_on_status_id"
    t.index ["tag_id", "status_id"], name: "index_statuses_tags_on_tag_id_and_status_id", unique: true
  end

  create_table "system_keys", force: :cascade do |t|
    t.binary "key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "tags", force: :cascade do |t|
    t.string "name", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "usable"
    t.boolean "trendable"
    t.boolean "listable"
    t.datetime "reviewed_at"
    t.datetime "requested_review_at"
    t.datetime "last_status_at"
    t.float "max_score"
    t.datetime "max_score_at"
    t.string "display_name"
    t.index "lower((name)::text) text_pattern_ops", name: "index_tags_on_name_lower_btree", unique: true
  end

  create_table "tag_account_mutes", force: :cascade do |t|
    t.bigint "tag_id"
    t.bigint "account_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["account_id"], name: "index_tag_account_mutes_on_account_id"
    t.index ["tag_id"], name: "index_tag_account_mutes_on_tag_id"
  end

  create_table "tag_follow_deliveries", force: :cascade do |t|
    t.bigint "tag_follow_id", null: false
    t.bigint "list_id"
    t.boolean "media_only", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "legacy_follow_tag_id"
    t.index ["legacy_follow_tag_id"], name: "index_tag_follow_deliveries_on_legacy_follow_tag_id", unique: true
    t.index ["list_id"], name: "index_tag_follow_deliveries_on_list_id"
    t.index ["tag_follow_id", "list_id"], name: "index_tag_follow_deliveries_on_list", unique: true, where: "(list_id IS NOT NULL)"
    t.index ["tag_follow_id"], name: "index_tag_follow_deliveries_on_home", unique: true, where: "(list_id IS NULL)"
    t.index ["tag_follow_id"], name: "index_tag_follow_deliveries_on_tag_follow_id"
  end

  create_table "tag_follows", force: :cascade do |t|
    t.bigint "tag_id", null: false
    t.bigint "account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id", "tag_id"], name: "index_tag_follows_on_account_id_and_tag_id", unique: true
    t.index ["tag_id"], name: "index_tag_follows_on_tag_id"
  end

  create_table "timeline_reading_bookmarks", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 100, null: false
    t.string "source", limit: 16, null: false
    t.jsonb "context", default: {}, null: false
    t.integer "anchor_version", default: 1, null: false
    t.string "anchor_status_id", limit: 19, null: false
    t.string "display_row_id", limit: 128
    t.integer "offset_px", null: false
    t.string "alignment", limit: 8, null: false
    t.datetime "captured_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["user_id", "name"], name: "index_timeline_reading_bookmarks_on_user_and_name", unique: true
    t.index ["user_id", "updated_at"], name: "index_timeline_reading_bookmarks_on_user_and_updated_at"
    t.check_constraint "((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 100)) AND ((name)::text !~ '[[:cntrl:]]'::text) AND (btrim((name)::text) = (name)::text) AND ((source)::text = ANY ((ARRAY['home'::character varying, 'limited'::character varying, 'list'::character varying, 'hashtag'::character varying, 'public'::character varying, 'domain'::character varying, 'group'::character varying, 'personal'::character varying])::text[])) AND ((alignment)::text = ANY ((ARRAY['top'::character varying, 'center'::character varying])::text[])) AND (anchor_version = 1) AND ((offset_px >= '-1000000'::integer) AND (offset_px <= 1000000)) AND ((anchor_status_id)::text ~ '^[1-9][0-9]{0,18}$'::text) AND ((display_row_id IS NULL) OR (((char_length((display_row_id)::text) >= 1) AND (char_length((display_row_id)::text) <= 128)) AND ((display_row_id)::text !~ '[[:cntrl:]]'::text))) AND (octet_length((context)::text) <= 2048)", name: "timeline_reading_bookmarks_shape"
  end

  create_table "tombstones", force: :cascade do |t|
    t.bigint "account_id"
    t.string "uri", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "by_moderator"
    t.index ["account_id"], name: "index_tombstones_on_account_id"
    t.index ["uri"], name: "index_tombstones_on_uri"
  end

  create_table "unavailable_domains", force: :cascade do |t|
    t.string "domain", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["domain"], name: "index_unavailable_domains_on_domain", unique: true
  end

  create_table "unresolve_status_reference_params", id: false, force: :cascade do |t|
    t.bigint "status_id", null: false
    t.jsonb "options"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["status_id"], name: "index_unresolve_status_reference_params_on_status_id"
  end

  create_table "user_external_credentials", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "provider", limit: 64, null: false
    t.string "purpose", limit: 64, null: false
    t.string "credential_type", limit: 64, null: false
    t.string "binding_id", limit: 36, null: false
    t.text "encrypted_payload", null: false
    t.string "encryption_key_id", limit: 32, null: false
    t.string "display_name", limit: 100
    t.datetime "expires_at"
    t.datetime "revoked_at"
    t.datetime "last_used_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["binding_id"], name: "index_user_external_credentials_on_binding_id", unique: true
    t.index ["encryption_key_id"], name: "index_user_external_credentials_on_encryption_key_id"
    t.index ["user_id", "provider", "purpose"], name: "index_user_external_credentials_on_owner_use"
  end

  create_table "user_invite_requests", force: :cascade do |t|
    t.bigint "user_id"
    t.text "text"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_user_invite_requests_on_user_id"
  end

  create_table "user_posting_context_assignments", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "surface_kind", limit: 16, null: false
    t.string "surface_key", limit: 100, null: false
    t.bigint "user_posting_context_id"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["user_id", "surface_kind", "surface_key"], name: "index_upca_on_user_id_and_surface", unique: true
    t.index ["user_posting_context_id"], name: "index_upca_on_user_posting_context_id"
  end

  create_table "user_posting_contexts", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 80, null: false
    t.string "icon", limit: 64
    t.text "purpose"
    t.string "target_kind", limit: 16, default: "none", null: false
    t.bigint "target_account_id"
    t.string "target_hashtag", limit: 100
    t.jsonb "defaults", default: {}, null: false
    t.jsonb "managed", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.boolean "enabled", default: true, null: false
    t.integer "schema_version", default: 1, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["target_account_id"], name: "index_user_posting_contexts_on_target_account_id"
    t.index ["user_id", "position"], name: "index_user_posting_contexts_on_user_id_and_position"
  end

  create_table "user_preference_revisions", primary_key: "user_id", id: :bigint, default: nil, force: :cascade do |t|
    t.bigint "revision", null: false
  end

  create_table "user_roles", force: :cascade do |t|
    t.string "name", default: "", null: false
    t.string "color", default: "", null: false
    t.integer "position", default: 0, null: false
    t.bigint "permissions", default: 0, null: false
    t.boolean "highlighted", default: false, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.inet "current_sign_in_ip"
    t.inet "last_sign_in_ip"
    t.boolean "admin", default: false, null: false
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.string "locale"
    t.string "encrypted_otp_secret"
    t.string "encrypted_otp_secret_iv"
    t.string "encrypted_otp_secret_salt"
    t.integer "consumed_timestep"
    t.boolean "otp_required_for_login", default: false, null: false
    t.datetime "last_emailed_at"
    t.string "otp_backup_codes", array: true
    t.string "filtered_languages", default: [], null: false, array: true
    t.bigint "account_id", null: false
    t.boolean "disabled", default: false, null: false
    t.boolean "moderator", default: false, null: false
    t.bigint "invite_id"
    t.string "remember_token"
    t.string "chosen_languages", array: true
    t.bigint "created_by_application_id"
    t.boolean "approved", default: true, null: false
    t.string "sign_in_token"
    t.datetime "sign_in_token_sent_at"
    t.string "webauthn_id"
    t.inet "sign_up_ip"
    t.boolean "skip_sign_in_token"
    t.string "time_zone"
    t.bigint "role_id"
    t.index ["account_id"], name: "index_users_on_account_id"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["created_by_application_id"], name: "index_users_on_created_by_application_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["remember_token"], name: "index_users_on_remember_token", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["role_id"], name: "index_users_on_role_id", where: "(role_id IS NOT NULL)"
  end

  create_table "web_push_subscriptions", force: :cascade do |t|
    t.string "endpoint", null: false
    t.string "key_p256dh", null: false
    t.string "key_auth", null: false
    t.json "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "access_token_id"
    t.bigint "user_id"
    t.index ["access_token_id"], name: "index_web_push_subscriptions_on_access_token_id"
    t.index ["user_id"], name: "index_web_push_subscriptions_on_user_id"
  end

  create_table "web_settings", force: :cascade do |t|
    t.json "data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_web_settings_on_user_id", unique: true
  end

  create_table "webauthn_credentials", force: :cascade do |t|
    t.string "external_id", null: false
    t.string "public_key", null: false
    t.string "nickname", null: false
    t.bigint "sign_count", default: 0, null: false
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  create_table "webhooks", force: :cascade do |t|
    t.string "url", null: false
    t.string "events", default: [], null: false, array: true
    t.string "secret", default: "", null: false
    t.boolean "enabled", default: true, null: false
    t.text "template"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["url"], name: "index_webhooks_on_url", unique: true
  end

  add_foreign_key "account_aliases", "accounts", on_delete: :cascade
  add_foreign_key "account_conversations", "accounts", on_delete: :cascade
  add_foreign_key "account_conversations", "conversations", on_delete: :cascade
  add_foreign_key "account_deletion_requests", "accounts", on_delete: :cascade
  add_foreign_key "account_domain_blocks", "accounts", name: "fk_206c6029bd", on_delete: :cascade
  add_foreign_key "account_identity_proofs", "accounts", on_delete: :cascade
  add_foreign_key "account_migrations", "accounts", column: "target_account_id", on_delete: :nullify
  add_foreign_key "account_migrations", "accounts", on_delete: :cascade
  add_foreign_key "account_moderation_notes", "accounts"
  add_foreign_key "account_moderation_notes", "accounts", column: "target_account_id"
  add_foreign_key "account_notes", "accounts", column: "target_account_id", on_delete: :cascade
  add_foreign_key "account_notes", "accounts", on_delete: :cascade
  add_foreign_key "account_pins", "accounts", column: "target_account_id", on_delete: :cascade
  add_foreign_key "account_pins", "accounts", on_delete: :cascade
  add_foreign_key "account_stats", "accounts", on_delete: :cascade
  add_foreign_key "account_statuses_cleanup_policies", "accounts", on_delete: :cascade
  add_foreign_key "account_subscribes", "accounts", column: "target_account_id", on_delete: :cascade
  add_foreign_key "account_subscribes", "accounts", on_delete: :cascade
  add_foreign_key "account_subscribes", "lists", on_delete: :cascade
  add_foreign_key "account_warnings", "accounts", column: "target_account_id", on_delete: :cascade
  add_foreign_key "account_warnings", "accounts", on_delete: :nullify
  add_foreign_key "accounts", "accounts", column: "moved_to_account_id", on_delete: :nullify
  add_foreign_key "action_review_requests", "accounts", column: "actor_account_id", on_delete: :nullify
  add_foreign_key "action_review_requests", "accounts", column: "reviewer_account_id", on_delete: :nullify
  add_foreign_key "admin_action_logs", "accounts", on_delete: :cascade
  add_foreign_key "announcement_mutes", "accounts", on_delete: :cascade
  add_foreign_key "announcement_mutes", "announcements", on_delete: :cascade
  add_foreign_key "announcement_reactions", "accounts", on_delete: :cascade
  add_foreign_key "announcement_reactions", "announcements", on_delete: :cascade
  add_foreign_key "announcement_reactions", "custom_emojis", on_delete: :cascade
  add_foreign_key "backups", "users", on_delete: :nullify
  add_foreign_key "blocks", "accounts", column: "target_account_id", name: "fk_9571bfabc1", on_delete: :cascade
  add_foreign_key "blocks", "accounts", name: "fk_4269e03e65", on_delete: :cascade
  add_foreign_key "bookmarks", "accounts", on_delete: :cascade
  add_foreign_key "bookmarks", "statuses", on_delete: :cascade
  add_foreign_key "canonical_email_blocks", "accounts", column: "reference_account_id", on_delete: :cascade
  add_foreign_key "circle_accounts", "accounts", on_delete: :cascade
  add_foreign_key "circle_accounts", "circles", on_delete: :cascade
  add_foreign_key "circle_accounts", "follows", on_delete: :cascade
  add_foreign_key "circles", "accounts", on_delete: :cascade
  add_foreign_key "conversation_mutes", "accounts", name: "fk_225b4212bb", on_delete: :cascade
  add_foreign_key "conversation_mutes", "conversations", on_delete: :cascade
  add_foreign_key "custom_filter_keywords", "custom_filters", on_delete: :cascade
  add_foreign_key "custom_filter_statuses", "custom_filters", on_delete: :cascade
  add_foreign_key "custom_filter_statuses", "statuses", on_delete: :cascade
  add_foreign_key "custom_filters", "accounts", on_delete: :cascade
  add_foreign_key "devices", "accounts", on_delete: :cascade
  add_foreign_key "devices", "oauth_access_tokens", column: "access_token_id", on_delete: :cascade
  add_foreign_key "domain_subscribes", "accounts", on_delete: :cascade
  add_foreign_key "domain_subscribes", "lists", on_delete: :cascade
  add_foreign_key "email_domain_blocks", "email_domain_blocks", column: "parent_id", on_delete: :cascade
  add_foreign_key "emoji_reactions", "accounts", on_delete: :cascade
  add_foreign_key "emoji_reactions", "custom_emojis", on_delete: :cascade
  add_foreign_key "emoji_reactions", "statuses", on_delete: :cascade
  add_foreign_key "encrypted_messages", "accounts", column: "from_account_id", on_delete: :cascade
  add_foreign_key "encrypted_messages", "devices", on_delete: :cascade
  add_foreign_key "external_feed_routes", "lists", name: "fk_external_feed_routes_list", on_delete: :cascade
  add_foreign_key "external_feed_routes", "users", name: "fk_external_feed_routes_user", on_delete: :cascade
  add_foreign_key "external_identities", "user_external_credentials", column: "credential_id", on_delete: :nullify
  add_foreign_key "external_identities", "users", on_delete: :cascade
  add_foreign_key "external_media_asset_resources", "external_media_assets", name: "fk_ext_media_asset_resources_asset", on_delete: :cascade
  add_foreign_key "external_media_asset_resources", "external_resources", name: "fk_ext_media_asset_resources_resource", on_delete: :cascade
  add_foreign_key "external_media_repoint_stages", "external_media_assets", name: "fk_ext_media_repoint_stages_asset", on_delete: :nullify
  add_foreign_key "external_media_repoint_stages", "external_status_projections", name: "fk_ext_media_repoint_stages_projection", on_delete: :nullify
  add_foreign_key "external_oauth_attempts", "users", on_delete: :cascade
  add_foreign_key "external_projection_attachments", "external_media_assets", name: "fk_ext_proj_attach_asset", on_delete: :restrict
  add_foreign_key "external_projection_attachments", "external_status_projections", name: "fk_ext_proj_attach_projection", on_delete: :cascade
  add_foreign_key "external_projection_attachments", "media_attachments", name: "fk_ext_proj_attach_media", on_delete: :restrict
  add_foreign_key "external_link_share_policies", "users", name: "fk_link_share_policies_user", on_delete: :cascade
  add_foreign_key "external_projection_failures", "external_resources", on_delete: :restrict
  add_foreign_key "external_projection_failures", "external_subscriptions", on_delete: :cascade
  add_foreign_key "external_projection_failures", "users", on_delete: :cascade
  add_foreign_key "external_projection_link_boost_states", "users", name: "fk_link_boost_states_user", on_delete: :cascade
  add_foreign_key "external_projection_link_boosts", "accounts", name: "fk_link_boosts_account", on_delete: :cascade
  add_foreign_key "external_projection_link_boosts", "external_projection_link_references", column: "link_reference_id", name: "fk_link_boosts_reference_row", on_delete: :cascade
  add_foreign_key "external_projection_link_boosts", "external_status_projections", name: "fk_link_boosts_projection", on_delete: :nullify
  add_foreign_key "external_projection_link_boosts", "statuses", column: "reference_status_id", name: "fk_link_boosts_reference_status", on_delete: :nullify
  add_foreign_key "external_projection_link_boosts", "statuses", column: "wrapper_status_id", name: "fk_link_boosts_wrapper", on_delete: :nullify
  add_foreign_key "external_projection_link_boosts", "users", name: "fk_link_boosts_user", on_delete: :cascade
  add_foreign_key "external_projection_link_references", "accounts", name: "fk_link_refs_account", on_delete: :cascade
  add_foreign_key "external_projection_link_references", "external_status_projections", name: "fk_link_refs_projection", on_delete: :nullify
  add_foreign_key "external_projection_link_references", "statuses", column: "reference_status_id", name: "fk_link_refs_status", on_delete: :nullify
  add_foreign_key "external_projection_link_references", "users", name: "fk_link_refs_user", on_delete: :cascade
  add_foreign_key "external_projection_suppressions", "external_resources", on_delete: :restrict
  add_foreign_key "external_projection_suppressions", "users", on_delete: :cascade
  add_foreign_key "external_resources", "external_actors", on_delete: :nullify
  add_foreign_key "external_resources", "external_sources", on_delete: :restrict
  add_foreign_key "external_status_projections", "accounts", on_delete: :restrict
  add_foreign_key "external_status_projections", "statuses", on_delete: :cascade
  add_foreign_key "external_status_projections", "users", on_delete: :restrict
  add_foreign_key "external_subscription_deletion_effects", "external_subscription_deletions", column: "external_subscription_deletion_id", name: "fk_deletion_effects_deletion", on_delete: :cascade
  add_foreign_key "external_subscription_deletions", "users", name: "fk_external_subscription_deletions_user", on_delete: :cascade
  add_foreign_key "external_subscriptions", "external_sources", on_delete: :restrict
  add_foreign_key "external_subscriptions", "users", on_delete: :cascade
  add_foreign_key "favourite_domains", "accounts", on_delete: :cascade
  add_foreign_key "favourite_tags", "accounts", on_delete: :cascade
  add_foreign_key "favourite_tags", "tags", on_delete: :cascade
  add_foreign_key "favourites", "accounts", name: "fk_5eb6c2b873", on_delete: :cascade
  add_foreign_key "favourites", "statuses", name: "fk_b0e856845e", on_delete: :cascade
  add_foreign_key "featured_tags", "accounts", on_delete: :cascade
  add_foreign_key "featured_tags", "tags", on_delete: :cascade
  add_foreign_key "follow_import_batches", "moderation_subjects", column: "subject_id", on_delete: :cascade
  add_foreign_key "follow_import_targets", "follow_import_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "follow_import_targets", "moderation_subjects", column: "target_subject_id", on_delete: :nullify
  add_foreign_key "follow_recommendation_suppressions", "accounts", on_delete: :cascade
  add_foreign_key "follow_requests", "accounts", column: "target_account_id", name: "fk_9291ec025d", on_delete: :cascade
  add_foreign_key "follow_requests", "accounts", name: "fk_76d644b0e7", on_delete: :cascade
  add_foreign_key "follow_tags", "accounts", on_delete: :cascade
  add_foreign_key "follow_tags", "lists", on_delete: :cascade
  add_foreign_key "follow_tags", "tags", on_delete: :cascade
  add_foreign_key "follows", "accounts", column: "target_account_id", name: "fk_745ca29eac", on_delete: :cascade
  add_foreign_key "follows", "accounts", name: "fk_32ed1b5560", on_delete: :cascade
  add_foreign_key "group_affiliations", "accounts", column: "group_account_id", on_delete: :cascade
  add_foreign_key "identities", "users", name: "fk_bea040f377", on_delete: :cascade
  add_foreign_key "imports", "accounts", name: "fk_6db1b6e408", on_delete: :cascade
  add_foreign_key "invites", "users", on_delete: :cascade
  add_foreign_key "keyword_subscribes", "accounts", on_delete: :cascade
  add_foreign_key "keyword_subscribes", "lists", on_delete: :cascade
  add_foreign_key "list_accounts", "accounts", on_delete: :cascade
  add_foreign_key "list_accounts", "follows", on_delete: :cascade
  add_foreign_key "list_accounts", "lists", on_delete: :cascade
  add_foreign_key "lists", "accounts", on_delete: :cascade
  add_foreign_key "login_activities", "users", on_delete: :cascade
  add_foreign_key "markers", "users", on_delete: :cascade
  add_foreign_key "media_attachments", "accounts", name: "fk_96dd81e81b", on_delete: :nullify
  add_foreign_key "media_attachments", "scheduled_statuses", on_delete: :nullify
  add_foreign_key "media_attachments", "statuses", on_delete: :nullify
  add_foreign_key "mentions", "accounts", name: "fk_970d43f9d1", on_delete: :cascade
  add_foreign_key "mentions", "statuses", on_delete: :cascade
  add_foreign_key "moderation_actions", "accounts", column: "moderator_account_id", on_delete: :nullify
  add_foreign_key "moderation_actions", "moderation_evidence_snapshots", column: "evidence_snapshot_id", on_delete: :nullify
  add_foreign_key "moderation_actions", "moderation_subjects", column: "subject_id", on_delete: :cascade
  add_foreign_key "moderation_evidence_snapshots", "moderation_subjects", column: "subject_id", on_delete: :cascade
  add_foreign_key "moderation_interaction_events", "moderation_subjects", column: "actor_subject_id", on_delete: :nullify
  add_foreign_key "moderation_interaction_events", "moderation_subjects", column: "target_subject_id", on_delete: :nullify
  add_foreign_key "moderation_rejection_events", "moderation_interaction_events", column: "preceding_interaction_event_id", on_delete: :nullify
  add_foreign_key "moderation_rejection_events", "moderation_subjects", column: "rejected_subject_id", on_delete: :nullify
  add_foreign_key "moderation_rejection_events", "moderation_subjects", column: "rejector_subject_id", on_delete: :nullify
  add_foreign_key "moderation_subjects", "accounts", on_delete: :nullify
  add_foreign_key "mutes", "accounts", column: "target_account_id", name: "fk_eecff219ea", on_delete: :cascade
  add_foreign_key "mutes", "accounts", name: "fk_b8d8daf315", on_delete: :cascade
  add_foreign_key "notifications", "accounts", column: "from_account_id", name: "fk_fbd6b0bf9e", on_delete: :cascade
  add_foreign_key "notifications", "accounts", name: "fk_c141c8ee55", on_delete: :cascade
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id", name: "fk_34d54b0a33", on_delete: :cascade
  add_foreign_key "oauth_access_grants", "users", column: "resource_owner_id", name: "fk_63b044929b", on_delete: :cascade
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id", name: "fk_f5fc4c1ee3", on_delete: :cascade
  add_foreign_key "oauth_access_tokens", "users", column: "resource_owner_id", name: "fk_e84df68546", on_delete: :cascade
  add_foreign_key "oauth_applications", "users", column: "owner_id", name: "fk_b0988c7c0a", on_delete: :cascade
  add_foreign_key "one_time_keys", "devices", on_delete: :cascade
  add_foreign_key "poll_votes", "accounts", on_delete: :cascade
  add_foreign_key "poll_votes", "polls", on_delete: :cascade
  add_foreign_key "polls", "accounts", on_delete: :cascade
  add_foreign_key "polls", "statuses", on_delete: :cascade
  add_foreign_key "posting_identity_delegations", "accounts", column: "posting_account_id", on_delete: :cascade
  add_foreign_key "posting_identity_delegations", "users", column: "grantee_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_delegations", "users", column: "grantor_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_media", "accounts", column: "posting_account_id", on_delete: :cascade
  add_foreign_key "posting_identity_media", "posting_identity_delegations", column: "delegation_id", on_delete: :cascade
  add_foreign_key "posting_identity_media", "users", column: "grantee_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_posts", "accounts", column: "posting_account_id", on_delete: :cascade
  add_foreign_key "posting_identity_posts", "posting_identity_delegations", column: "delegation_id", on_delete: :cascade
  add_foreign_key "posting_identity_posts", "users", column: "grantee_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_link_requests", "users", column: "requester_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_link_requests", "posting_identity_request_allowances", column: "request_allowance_id", on_delete: :nullify
  add_foreign_key "posting_identity_request_allowances", "users", column: "grantor_user_id", on_delete: :cascade
  add_foreign_key "posting_identity_request_allowances", "users", column: "requester_user_id", on_delete: :cascade

  add_foreign_key "posting_identity_link_requests", "users", column: "target_user_id", on_delete: :cascade
  add_foreign_key "preview_card_trends", "preview_cards", on_delete: :cascade
  add_foreign_key "report_notes", "accounts", on_delete: :cascade
  add_foreign_key "report_notes", "reports", on_delete: :cascade
  add_foreign_key "reports", "accounts", column: "action_taken_by_account_id", name: "fk_bca45b75fd", on_delete: :nullify
  add_foreign_key "reports", "accounts", column: "assigned_account_id", on_delete: :nullify
  add_foreign_key "reports", "accounts", column: "target_account_id", name: "fk_eb37af34f0", on_delete: :cascade
  add_foreign_key "reports", "accounts", name: "fk_4b81f7522c", on_delete: :cascade
  add_foreign_key "scheduled_statuses", "accounts", on_delete: :cascade
  add_foreign_key "session_activations", "oauth_access_tokens", column: "access_token_id", name: "fk_957e5bda89", on_delete: :cascade
  add_foreign_key "session_activations", "users", name: "fk_e5fda67334", on_delete: :cascade
  add_foreign_key "status_capability_tokens", "statuses", on_delete: :cascade
  add_foreign_key "status_edits", "accounts", on_delete: :nullify
  add_foreign_key "status_edits", "statuses", on_delete: :cascade
  add_foreign_key "status_expires", "statuses", on_delete: :cascade
  add_foreign_key "status_pins", "accounts", name: "fk_d4cb435b62", on_delete: :cascade
  add_foreign_key "status_pins", "statuses", on_delete: :cascade
  add_foreign_key "status_references", "statuses", column: "target_status_id", on_delete: :cascade
  add_foreign_key "status_references", "statuses", on_delete: :cascade
  add_foreign_key "status_stats", "statuses", on_delete: :cascade
  add_foreign_key "status_trends", "accounts", on_delete: :cascade
  add_foreign_key "status_trends", "statuses", on_delete: :cascade
  add_foreign_key "statuses", "accounts", column: "audience_account_id", on_delete: :nullify
  add_foreign_key "statuses", "accounts", column: "in_reply_to_account_id", name: "fk_c7fa917661", on_delete: :nullify
  add_foreign_key "statuses", "accounts", name: "fk_9bda1543f7", on_delete: :cascade
  add_foreign_key "statuses", "generators", on_delete: :cascade
  add_foreign_key "statuses", "statuses", column: "in_reply_to_id", on_delete: :nullify
  add_foreign_key "statuses", "statuses", column: "reblog_of_id", on_delete: :cascade
  add_foreign_key "statuses_tags", "statuses", on_delete: :cascade
  add_foreign_key "statuses_tags", "tags", name: "fk_3081861e21", on_delete: :cascade
  add_foreign_key "tag_follow_deliveries", "lists", on_delete: :cascade
  add_foreign_key "tag_follow_deliveries", "tag_follows", on_delete: :cascade
  add_foreign_key "tag_follows", "accounts", on_delete: :cascade
  add_foreign_key "tag_follows", "tags", on_delete: :cascade
  add_foreign_key "timeline_reading_bookmarks", "users", on_delete: :cascade
  add_foreign_key "tombstones", "accounts", on_delete: :cascade
  add_foreign_key "user_external_credentials", "users", on_delete: :cascade
  add_foreign_key "user_invite_requests", "users", on_delete: :cascade
  add_foreign_key "user_posting_context_assignments", "user_posting_contexts", on_delete: :nullify
  add_foreign_key "user_posting_context_assignments", "users", on_delete: :cascade
  add_foreign_key "user_posting_contexts", "accounts", column: "target_account_id", on_delete: :nullify
  add_foreign_key "user_posting_contexts", "users", on_delete: :cascade
  add_foreign_key "user_preference_revisions", "users", on_delete: :cascade
  add_foreign_key "users", "accounts", name: "fk_50500f500d", on_delete: :cascade
  add_foreign_key "users", "invites", on_delete: :nullify
  add_foreign_key "users", "oauth_applications", column: "created_by_application_id", on_delete: :nullify
  add_foreign_key "users", "user_roles", column: "role_id", on_delete: :nullify
  add_foreign_key "web_push_subscriptions", "oauth_access_tokens", column: "access_token_id", on_delete: :cascade
  add_foreign_key "web_push_subscriptions", "users", on_delete: :cascade
  add_foreign_key "web_settings", "users", name: "fk_11910667b2", on_delete: :cascade
  add_foreign_key "webauthn_credentials", "users"

  create_view "instances", materialized: true, sql_definition: <<-SQL
      WITH domain_counts(domain, accounts_count) AS (
           SELECT accounts.domain,
              count(*) AS accounts_count
             FROM accounts
            WHERE (accounts.domain IS NOT NULL)
            GROUP BY accounts.domain
          )
   SELECT domain_counts.domain,
      domain_counts.accounts_count
     FROM domain_counts
  UNION
   SELECT domain_blocks.domain,
      COALESCE(domain_counts.accounts_count, (0)::bigint) AS accounts_count
     FROM (domain_blocks
       LEFT JOIN domain_counts ON (((domain_counts.domain)::text = (domain_blocks.domain)::text)))
  UNION
   SELECT domain_allows.domain,
      COALESCE(domain_counts.accounts_count, (0)::bigint) AS accounts_count
     FROM (domain_allows
       LEFT JOIN domain_counts ON (((domain_counts.domain)::text = (domain_allows.domain)::text)));
  SQL
  add_index "instances", ["domain"], name: "index_instances_on_domain", unique: true

  create_view "account_summaries", materialized: true, sql_definition: <<-SQL
      SELECT accounts.id AS account_id,
      mode() WITHIN GROUP (ORDER BY t0.language) AS language,
      mode() WITHIN GROUP (ORDER BY t0.sensitive) AS sensitive
     FROM (accounts
       CROSS JOIN LATERAL ( SELECT statuses.account_id,
              statuses.language,
              statuses.sensitive
             FROM statuses
            WHERE ((statuses.account_id = accounts.id) AND (statuses.deleted_at IS NULL) AND (statuses.reblog_of_id IS NULL))
            ORDER BY statuses.id DESC
           LIMIT 20) t0)
    WHERE ((accounts.suspended_at IS NULL) AND (accounts.silenced_at IS NULL) AND (accounts.moved_to_account_id IS NULL) AND (accounts.discoverable = true) AND (accounts.locked = false))
    GROUP BY accounts.id;
  SQL
  add_index "account_summaries", ["account_id"], name: "index_account_summaries_on_account_id", unique: true

  create_view "follow_recommendations", materialized: true, sql_definition: <<-SQL
      SELECT t0.account_id,
      sum(t0.rank) AS rank,
      array_agg(t0.reason) AS reason
     FROM ( SELECT account_summaries.account_id,
              ((count(follows.id))::numeric / (1.0 + (count(follows.id))::numeric)) AS rank,
              'most_followed'::text AS reason
             FROM (((follows
               JOIN account_summaries ON ((account_summaries.account_id = follows.target_account_id)))
               JOIN users ON ((users.account_id = follows.account_id)))
               LEFT JOIN follow_recommendation_suppressions ON ((follow_recommendation_suppressions.account_id = follows.target_account_id)))
            WHERE ((users.current_sign_in_at >= (now() - 'P30D'::interval)) AND (account_summaries.sensitive = false) AND (follow_recommendation_suppressions.id IS NULL))
            GROUP BY account_summaries.account_id
           HAVING (count(follows.id) >= 5)
          UNION ALL
           SELECT account_summaries.account_id,
              (sum(((status_stats.reblogs_count + status_stats.favourites_count) + status_stats.emoji_reactions_count)) / (1.0 + sum(((status_stats.reblogs_count + status_stats.favourites_count) + status_stats.emoji_reactions_count)))) AS rank,
              'most_interactions'::text AS reason
             FROM (((status_stats
               JOIN statuses ON ((statuses.id = status_stats.status_id)))
               JOIN account_summaries ON ((account_summaries.account_id = statuses.account_id)))
               LEFT JOIN follow_recommendation_suppressions ON ((follow_recommendation_suppressions.account_id = statuses.account_id)))
            WHERE ((statuses.id >= (((date_part('epoch'::text, (now() - 'P30D'::interval)) * (1000)::double precision))::bigint << 16)) AND (account_summaries.sensitive = false) AND (follow_recommendation_suppressions.id IS NULL))
            GROUP BY account_summaries.account_id
           HAVING (sum(((status_stats.reblogs_count + status_stats.favourites_count) + status_stats.emoji_reactions_count)) >= (5)::numeric)) t0
    GROUP BY t0.account_id
    ORDER BY (sum(t0.rank)) DESC;
  SQL
  add_index "follow_recommendations", ["account_id"], name: "index_follow_recommendations_on_account_id", unique: true

  create_view "user_ips", sql_definition: <<-SQL
      SELECT user_id,
      ip,
      max(used_at) AS used_at
     FROM ( SELECT users.id AS user_id,
              users.sign_up_ip AS ip,
              users.created_at AS used_at
             FROM users
            WHERE (users.sign_up_ip IS NOT NULL)
          UNION ALL
           SELECT session_activations.user_id,
              session_activations.ip,
              session_activations.updated_at
             FROM session_activations
          UNION ALL
           SELECT login_activities.user_id,
              login_activities.ip,
              login_activities.created_at
             FROM login_activities
            WHERE (login_activities.success = true)) t0
    GROUP BY user_id, ip;
  SQL

  # Composite foreign keys and projection triggers are not represented by the
  # Rails 6.1 schema dumper. schema:load executes the application definition.
  execute ExternalBridge::Schema::DEFINITIONS_SQL
end
