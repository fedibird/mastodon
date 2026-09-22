# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db', 'migrate', '20260922060000_add_match_hashtags_and_match_urls_to_keyword_subscribes.rb')

# Raw regexp subscriptions predate the two options and were written against an
# unrestricted body string, so the migration opts them into both rather than
# silently narrowing them to body only matching.
RSpec.describe AddMatchHashtagsAndMatchUrlsToKeywordSubscribes do
  subject(:migration) { described_class.new }

  let(:account) { Fabricate(:account) }
  let!(:regexp_subscribe) { KeywordSubscribe.create!(account: account, name: 'raw', keyword: 'fo+o', regexp: true) }
  let!(:keyword_subscribe) { KeywordSubscribe.create!(account: account, name: 'plain', keyword: 'foo', regexp: false) }

  # The columns already exist in the loaded test schema, so the data transition is
  # exercised by reverting the migration and running it again over existing rows.
  before do
    migration.suppress_messages do
      migration.migrate(:down)
      KeywordSubscribe.reset_column_information
      migration.migrate(:up)
    end

    KeywordSubscribe.reset_column_information
  end

  it 'opts a pre-existing raw regexp subscription into hashtag matching' do
    expect(regexp_subscribe.reload.match_hashtags).to be true
  end

  it 'opts a pre-existing raw regexp subscription into URL matching' do
    expect(regexp_subscribe.reload.match_urls).to be true
  end

  it 'leaves a pre-existing keyword subscription on the defaults' do
    expect(keyword_subscribe.reload).to have_attributes(match_hashtags: false, match_urls: false)
  end
end
