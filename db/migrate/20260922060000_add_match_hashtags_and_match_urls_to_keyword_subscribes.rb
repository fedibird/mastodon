# frozen_string_literal: true

class AddMatchHashtagsAndMatchUrlsToKeywordSubscribes < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      change_table :keyword_subscribes, bulk: true do |t|
        t.column :match_hashtags, :boolean, default: false, null: false
        t.column :match_urls, :boolean, default: false, null: false
      end

      # Raw regexp subscriptions were written against an unrestricted body
      # string, so they are opted into both new options instead of being
      # silently narrowed to body only matching. Keyword subscriptions keep the
      # new defaults.
      execute <<~SQL.squish
        UPDATE keyword_subscribes
        SET match_hashtags = TRUE, match_urls = TRUE
        WHERE regexp = TRUE
      SQL
    end
  end

  def down
    safety_assured do
      change_table :keyword_subscribes, bulk: true do |t|
        t.remove :match_urls
        t.remove :match_hashtags
      end
    end
  end
end
