# frozen_string_literal: true

require 'rails_helper'

describe TimelineReadingBookmarks::Contract do
  def anchor(extra = {})
    {
      version: 1,
      status_id: '109717037387162260',
      offset_px: 8,
      alignment: 'top',
    }.merge(extra)
  end

  def build(payload)
    described_class.build(payload)
  end

  it 'canonicalizes a home anchor and strips the name' do
    attrs = build(
      name: "  Morning\tplace  ".tr("\t", ' '),
      source: 'home',
      context: { visibilities: %w(private public public) },
      anchor: anchor
    )

    expect(attrs[:name]).to eq('Morning place')
    expect(attrs[:source]).to eq('home')
    expect(attrs[:context]).to eq('visibilities' => %w(private public))
    expect(attrs[:anchor_status_id]).to eq('109717037387162260')
    expect(attrs[:offset_px]).to eq(8)
    expect(attrs.keys).not_to include(:text, :window, :view)
  end

  it 'stores a list id once and rejects a mismatched alias' do
    attrs = build(name: 'List', source: 'list', context: { list_id: '42' }, anchor: anchor)

    expect(attrs[:context]).to eq('id' => '42')
    expect(described_class.timeline_id('list', attrs[:context])).to eq('list:42')

    expect { build(name: 'List', source: 'list', context: { id: '2', list_id: '9' }, anchor: anchor) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error| expect(error.code).to eq('source_mismatch') }
  end

  it 'rejects search text, windows, and unknown fields without echoing them' do
    expect { build(name: 'Find', source: 'home', context: { q: 'hidden-query-zz' }, anchor: anchor) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error|
        expect(error.code).to eq('search_or_content_not_accepted')
        expect(error.message).not_to include('hidden-query-zz')
      }

    expect { build(name: 'Window', source: 'public', statuses: %w(1 2), anchor: anchor) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error| expect(error.code).to eq('window_not_accepted') }

    expect { build(name: 'View', source: 'home', view: { columnId: 'column-secret' }, anchor: anchor) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error|
        expect(error.code).to eq('unsupported_field')
        expect(error.message).not_to include('column-secret')
      }
  end

  it 'rejects a timeline id that points at a different source' do
    expect {
      build(name: 'Spoof', source: 'home', source_timeline_id: 'list:99', context: {}, anchor: anchor)
    }.to raise_error(TimelineReadingBookmarks::Reject) { |error| expect(error.code).to eq('source_mismatch') }
  end

  it 'keeps hashtag filters and a normalized domain, not a local flag' do
    hashtag = build(
      name: 'Tag',
      source: 'hashtag',
      context: { hashtag: '#News', any: ['fedibird'], all: [], none: nil },
      anchor: anchor
    )
    domain = build(
      name: 'Domain',
      source: 'domain',
      source_timeline_id: 'domain:Example.COM',
      context: { domain: 'Example.COM', local: false, only_media: 'true' },
      anchor: anchor
    )

    expect(hashtag[:context]).to eq('hashtag' => 'News', 'any' => ['fedibird'])
    expect(domain[:context]).to include('domain' => 'example.com', 'only_media' => true, 'without_media' => false)
    expect(domain[:context]).not_to have_key('local')
  end

  it 'rejects closed sources, status bodies, and a display row for another status' do
    expect { build(name: 'Mix', source: 'mix', anchor: anchor) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error| expect(error.code).to eq('invalid_source') }

    expect { build(name: 'Body', source: 'home', anchor: anchor.merge(status_id: '15'), text: 'secret-status-body') }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error|
        expect(error.code).to eq('search_or_content_not_accepted')
        expect(error.message).not_to include('secret-status-body')
      }

    expect { build(name: 'Row', source: 'home', anchor: anchor.merge(status_id: '15', display_row_id: 'f-16')) }
      .to raise_error(TimelineReadingBookmarks::Reject) { |error| expect(error.code).to eq('invalid_anchor') }
  end

  it 'redacts search keys in logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(context: { q: 'hidden-query-zz', text: 'secret-status-body' }, window: [1])

    expect(filtered[:context][:q]).to eq('[FILTERED]')
    expect(filtered[:context][:text]).to eq('[FILTERED]')
    expect(filtered[:window]).to eq('[FILTERED]')
    expect(filtered.to_s).not_to include('hidden-query-zz')
  end
end
