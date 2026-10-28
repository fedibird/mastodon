# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength

RSpec.describe ExternalBridge::RSS::PublicationTime do
  def snowflake_second(id)
    (id >> 16) / 1000
  end

  def bundle_for(user, published_at:, created_at: Time.utc(2024, 1, 15, 8, 0, 0), fetched_at: Time.utc(2024, 8, 1, 12, 0, 0))
    source = ExternalSource.create!(
      protocol: 'rss',
      canonical_key: "https://feeds.example/#{SecureRandom.hex(6)}.xml",
      title: 'Example feed',
      site_url: 'https://example.test',
      fetched_at: fetched_at,
      checked_at: fetched_at
    )
    resource = ExternalResource.create!(
      external_source: source,
      protocol: 'rss',
      canonical_key: "feed:#{source.canonical_key}\nitem:#{SecureRandom.hex(4)}",
      title: 'Example title',
      body: 'Example body',
      canonical_url: "https://example.test/posts/#{SecureRandom.hex(4)}",
      byline: 'Ada',
      revision: 'rev-1',
      published_at: published_at,
      fetched_at: fetched_at,
      created_at: created_at,
      updated_at: created_at
    )
    subscription = ExternalSubscription.create!(user: user, external_source: source, state: 'active')
    { source: source, resource: resource, subscription: subscription }
  end

  def project!(user, bundle)
    ExternalBridge::ProjectionWriter.new.create!(
      user: user,
      subscription: bundle[:subscription],
      resource: bundle[:resource]
    )
  end

  describe '.parse' do
    it 'rejects a clock time, a date without a timezone, and an impossible day' do
      expect(described_class.parse('10:00:00')).to be_nil
      expect(described_class.parse('2020-01-02')).to be_nil
      expect(described_class.parse('2020-01-02T03:04:05')).to be_nil
      expect(described_class.parse('2020-02-31T00:00:00Z')).to be_nil
      expect(described_class.parse('Thu, 02 Jan 2020')).to be_nil
    end
  end

  describe 'new projections' do
    let(:user) { Fabricate(:user) }
    let(:other) { Fabricate(:user) }

    before { Setting.external_bridge_external_visibility = true }
    after { Setting.external_bridge_external_visibility = false }

    it 'mints the snowflake id from the publication instant and leaves updated_at as the save time' do
      published = Time.utc(2024, 3, 3, 11, 0, 0)
      status, = project!(user, bundle_for(user, published_at: published))

      expect(status.created_at).to eq published
      expect(status.updated_at).to be_within(5.seconds).of(Time.current)
      expect(status.updated_at).not_to eq status.created_at
      expect(status.override_timestamps).to be_nil
      expect(snowflake_second(status.id)).to eq published.to_i
      expect(status.visibility).to eq 'external'
    end

    it 'uses the first observation when the feed date is missing, future, pre-epoch, or outside the snowflake range' do
      observed = Time.utc(2024, 6, 1, 8, 30, 0)
      fetched = Time.utc(2024, 8, 1, 12, 0, 0)
      cases = [
        nil,
        2.days.from_now,
        Time.utc(1969, 12, 31, 23, 0, 0),
        Time.utc(9999, 1, 1),
      ]

      cases.each do |published|
        bundle = bundle_for(user, published_at: published, created_at: observed, fetched_at: fetched)
        status, = project!(user, bundle)

        expect(status.created_at).to eq observed
        expect(snowflake_second(status.id)).to eq observed.to_i
        expect(status.created_at).not_to eq fetched
        expect(bundle[:resource].reload.published_at&.to_i).to eq published&.to_i
        expect(bundle[:resource].fetched_at).to eq fetched
      end
    end

    it 'keeps the issued id when the article is edited or the date is corrected or dropped' do
      published = Time.utc(2024, 3, 3, 11, 0, 0)
      bundle = bundle_for(user, published_at: published)
      status, marker = project!(user, bundle)
      original_id = status.id
      enable_external_bridge_rss!(user)

      bundle[:resource].update!(
        title: 'Edited title',
        body: 'Edited body',
        revision: Digest::SHA256.hexdigest('edited'),
        published_at: Time.utc(2019, 5, 5, 5, 5, 5),
        fetched_at: Time.current
      )
      ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])

      reloaded = status.reload
      expect(reloaded.id).to eq original_id
      expect(reloaded.created_at).to eq published
      expect(reloaded.text).to include('Edited title')
      expect(marker.reload.last_seen_revision).to eq bundle[:resource].revision

      bundle[:resource].update!(published_at: nil, fetched_at: Time.current, revision: Digest::SHA256.hexdigest('dropped'))
      ExternalBridge::RSS::Materialize.new.call(subscription: bundle[:subscription], resources: [bundle[:resource].reload])

      expect(status.reload.id).to eq original_id
      expect(status.created_at).to eq published
    end

    it 'gives two subscribers and two articles from the same second distinct ids in that second' do
      published = Time.utc(2024, 3, 3, 10, 0, 0)
      first_user = bundle_for(user, published_at: published)
      second_user = {
        source: first_user[:source],
        resource: first_user[:resource],
        subscription: ExternalSubscription.create!(user: other, external_source: first_user[:source], state: 'active'),
      }
      same_second = bundle_for(user, published_at: published)
      left, = project!(user, first_user)
      right, = project!(other, second_user)
      third, = project!(user, same_second)

      expect([left.id, right.id, third.id].uniq.size).to eq 3
      expect([left, right, third].map { |status| snowflake_second(status.id) }.uniq).to eq [published.to_i]
    end
  end
end
# rubocop:enable Metrics/BlockLength
