class AddMatchHashtagsAndMatchUrlsToKeywordSubscribes < ActiveRecord::Migration[6.1]
  def change
    add_column :keyword_subscribes, :match_hashtags, :boolean, default: false, null: false
    add_column :keyword_subscribes, :match_urls, :boolean, default: false, null: false
  end
end
