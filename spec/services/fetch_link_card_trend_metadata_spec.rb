# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FetchLinkCardService do
  subject { described_class.new }

  let(:card) { PreviewCard.new(type: :link, title: '会社概要', description: '会社について') }

  before do
    subject.instance_variable_set(:@card, card)
  end

  def page_for(html)
    Nokogiri::HTML(html)
  end

  it 'keeps a normal titled page unknown' do
    page = page_for('<html lang="ja"><head><title>会社概要</title><meta name="description" content="会社について"></head></html>')

    subject.send(:assign_trend_metadata, page)

    expect(card.link_type).to eq 'unknown'
    expect(card.language).to eq 'ja'
  end

  it 'marks og:type article and reads og:locale before html lang' do
    page = page_for('<html lang="ja"><head><meta property="og:type" content="article"><meta property="og:locale" content="en_US"><meta property="og:image:alt" content="Photo"><meta property="article:published_time" content="2024-05-01T00:00:00Z"></head></html>')

    subject.send(:assign_trend_metadata, page)

    expect(card.link_type).to eq 'article'
    expect(card.language).to eq 'en'
    expect(card.image_description).to eq 'Photo'
    expect(card.published_at).to eq Time.utc(2024, 5, 1)
  end

  it 'marks JSON-LD NewsArticle and uses inLanguage' do
    page = page_for(<<~HTML)
      <html lang="ja">
        <script type="application/ld+json">{"@type":"NewsArticle","inLanguage":"fr","datePublished":"2024-06-01T00:00:00Z"}</script>
      </html>
    HTML

    subject.send(:assign_trend_metadata, page)

    expect(card.link_type).to eq 'article'
    expect(card.language).to eq 'fr'
    expect(card.published_at).to eq Time.utc(2024, 6, 1)
  end

  it 'clears article when a previously classified card is no longer an article' do
    card.link_type = :article
    page = page_for('<html><head><meta property="og:type" content="website"></head></html>')

    subject.send(:assign_trend_metadata, page)

    expect(card.link_type).to eq 'unknown'
  end
end
