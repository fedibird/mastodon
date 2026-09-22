# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'migrate', '20260922060000_add_match_hashtags_and_match_urls_to_keyword_subscribes.rb')

# Raw regexp subscriptions predate the two options and were written against an
# unrestricted body string, so the migration opts them into both rather than
# silently narrowing them to body only matching.
RSpec.describe AddMatchHashtagsAndMatchUrlsToKeywordSubscribes do
  subject(:migration) { described_class.new }

  let(:account) { Fabricate(:account) }

  # The columns already exist in the loaded test schema, so the data transition is
  # exercised by reverting the migration and running it again over existing rows.
  # One example keeps that to a single DDL round trip.
  it 'opts pre-existing raw regexp rows into both options and leaves keyword rows alone' do
    regexp_subscribe = KeywordSubscribe.create!(account: account, name: 'raw', keyword: 'fo+o', regexp: true)
    keyword_subscribe = KeywordSubscribe.create!(account: account, name: 'plain', keyword: 'foo', regexp: false)

    migration.suppress_messages do
      migration.migrate(:down)
      KeywordSubscribe.reset_column_information
      migration.migrate(:up)
    end

    KeywordSubscribe.reset_column_information

    aggregate_failures do
      expect(regexp_subscribe.reload).to have_attributes(match_hashtags: true, match_urls: true)
      expect(keyword_subscribe.reload).to have_attributes(match_hashtags: false, match_urls: false)
    end
  end
end
