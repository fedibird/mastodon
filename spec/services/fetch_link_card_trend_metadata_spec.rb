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

  def stub_image_download
    card.define_singleton_method(:image_remote_url) { nil }
    allow(card).to receive(:image_remote_url=) { |url| card.define_singleton_method(:image_remote_url) { url } }
    allow(card).to receive(:image) do
      instance_double(Paperclip::Attachment, present?: card.image_remote_url.present?)
    end
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

  it 'becomes trend-eligible from JSON-LD metadata plus og:image' do
    subject.instance_variable_set(:@url, 'https://news.example/story')
    stub_image_download
    page = page_for(<<~HTML)
      <html>
        <head>
          <meta property="og:image" content="https://news.example/cover.jpg">
        </head>
        <script type="application/ld+json">
          {
            "@type": "NewsArticle",
            "headline": "ニュース記事",
            "description": "本文概要",
            "image": "https://news.example/jsonld-only.jpg",
            "publisher": { "name": "Example News" },
            "inLanguage": "ja",
            "datePublished": "2024-07-01T00:00:00Z"
          }
        </script>
      </html>
    HTML

    subject.send(:apply_preview_card_details, page)

    expect(card.link_type).to eq 'article'
    expect(card.title).to eq 'ニュース記事'
    expect(card.description).to eq '本文概要'
    expect(card.provider_name).to eq 'Example News'
    expect(card.image_remote_url).to eq 'https://news.example/cover.jpg'
    expect(card.language).to eq 'ja'
    expect(card.published_at).to eq Time.utc(2024, 7, 1)
    expect(card).to be_appropriate_for_trends
  end

  it 'does not use a JSON-LD image when og:image is absent' do
    subject.instance_variable_set(:@url, 'https://news.example/story')
    stub_image_download
    page = page_for(<<~HTML)
      <html>
        <script type="application/ld+json">
          {
            "@type": "NewsArticle",
            "headline": "ニュース記事",
            "description": "本文概要",
            "image": "https://news.example/jsonld-only.jpg",
            "publisher": { "name": "Example News" }
          }
        </script>
      </html>
    HTML

    subject.send(:apply_preview_card_details, page)

    expect(card.image_remote_url).to be_nil
    expect(card).not_to be_appropriate_for_trends
  end

  it 'does not classify a card when oEmbed succeeds' do
    subject.instance_variable_set(:@url, 'https://news.example/story')
    subject.instance_variable_set(:@html, '<html><head><meta property="og:type" content="article"></head></html>')
    embed_service = instance_double(FetchOEmbedService, endpoint_url: 'https://news.example/oembed')
    allow(embed_service).to receive(:call).and_return(type: 'link', title: 'Embed', provider_name: 'Example')
    allow(FetchOEmbedService).to receive(:new).and_return(embed_service)
    allow(card).to receive(:save_with_optional_image!)

    expect(subject.send(:attempt_oembed)).not_to eq false
    expect(card.link_type).to be_nil
    expect(card.title).to eq 'Embed'
  end

  it 'uses the JSON-LD publisher when og:site_name is missing' do
    subject.instance_variable_set(:@url, 'https://news.example/story')
    stub_image_download
    page = page_for(<<~HTML)
      <html>
        <head>
          <title>ニュース記事</title>
          <meta name="description" content="本文概要">
          <meta property="og:image" content="https://news.example/cover.jpg">
        </head>
        <script type="application/ld+json">
          {"@type":"NewsArticle","publisher":{"name":"Example News"}}
        </script>
      </html>
    HTML

    subject.send(:apply_preview_card_details, page)

    expect(card.provider_name).to eq 'Example News'
    expect(card).to be_appropriate_for_trends
  end

  it 'clears article when a previously classified card is no longer an article' do
    card.link_type = :article
    page = page_for('<html><head><meta property="og:type" content="website"></head></html>')

    subject.send(:assign_trend_metadata, page)

    expect(card.link_type).to eq 'unknown'
  end
end
