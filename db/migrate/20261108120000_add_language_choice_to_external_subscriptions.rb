# frozen_string_literal: true

# Per-subscription language for RSS projections (issue #617).
#
# language_mode is unspecified, auto, or fixed. language is the code only
# when the mode is fixed. Both columns belong to the subscriber. The shared
# source and resource rows are not changed.
#
# New and existing rows start as unspecified with a NULL code. PostgreSQL 11+
# stores the constant default in the catalog, so existing subscription rows
# are not rewritten. This migration does not read or update `statuses`.
# Imported posts keep whatever language they already have (NULL, because
# projections did not set one) until a later presentation pass, and only for
# the subscriber who changes the setting.
#
# Rollback drops these columns. It does not rewrite `statuses` either:
# a language already copied onto a status stays there, and the setting that
# produced it is gone. Run the presentation pass again only after migrating
# forward. The check is NOT VALID so PostgreSQL enforces it for later writes
# without scanning subscription rows that already match the default.
class AddLanguageChoiceToExternalSubscriptions < ActiveRecord::Migration[6.1]
  # strong_migrations cannot inspect change_table bulk: true.
  # rubocop:disable Rails/BulkChangeTable
  def change
    add_column :external_subscriptions, :language_mode, :string, null: false, default: 'unspecified'
    add_column :external_subscriptions, :language, :string, limit: 32
    add_check_constraint :external_subscriptions, <<~SQL.squish, name: 'external_subscriptions_language_check', validate: false
      language_mode IN ('unspecified', 'auto', 'fixed')
      AND (
        (language_mode = 'fixed' AND language IS NOT NULL AND btrim(language) <> '')
        OR (language_mode <> 'fixed' AND language IS NULL)
      )
    SQL
  end
  # rubocop:enable Rails/BulkChangeTable
end
