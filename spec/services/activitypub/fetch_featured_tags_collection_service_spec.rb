require 'rails_helper'

RSpec.describe ActivityPub::FetchFeaturedTagsCollectionService, type: :service do
  let(:account) { Fabricate(:account, domain: 'remote.example', uri: 'https://remote.example/users/alice') }
  let(:service) { described_class.new }

  describe '#process_items' do
    let(:alpha) { Fabricate(:tag, name: 'alpha') }
    let(:beta) { Fabricate(:tag, name: 'beta') }
    let(:kept_tag) { Fabricate(:tag, name: 'kept') }
    let(:older_alpha) { tag_status(alpha, created_at: Time.utc(2026, 1, 2, 0, 0, 0)) }
    let(:newer_alpha) { tag_status(alpha, created_at: Time.utc(2026, 1, 3, 0, 0, 0)) }
    let(:beta_status) { tag_status(beta, created_at: Time.utc(2026, 2, 1, 0, 0, 0)) }
    let!(:kept) do
      tag_status(kept_tag, created_at: Time.utc(2026, 3, 1, 0, 0, 0))
      FeaturedTag.create!(account: account, name: 'kept', url: 'https://remote.example/tags/kept').tap do |featured_tag|
        featured_tag.update_columns(statuses_count: 99, last_status_at: Time.utc(2020, 1, 1))
      end
    end
    let!(:removed) { FeaturedTag.create!(account: account, name: 'gone', url: 'https://remote.example/tags/gone') }

    before do
      older_alpha
      newer_alpha
      tag_status(alpha, visibility: :private, created_at: Time.utc(2026, 6, 1, 0, 0, 0))
      tag_status(alpha, created_at: Time.utc(2026, 6, 2, 0, 0, 0)).discard
      tag_status(alpha, created_at: Time.utc(2026, 6, 3, 0, 0, 0)).update_column(:expired_at, Time.utc(2026, 6, 4, 0, 0, 0))
      beta_status
    end

    it 'counts new remote tags once and leaves existing featured tags unchanged' do
      service.instance_variable_set(:@account, account)
      queries = capture_sql { service.send(:process_items, items) }

      expect(featured_count('alpha')).to eq(2)
      expect(featured_count('beta')).to eq(1)
      expect(featured_count('gamma')).to eq(0)
      expect(featured_tag('alpha').last_status_at).to eq(newer_alpha.reload.created_at)
      expect(featured_tag('beta').last_status_at).to eq(beta_status.reload.created_at)
      expect(featured_tag('gamma').last_status_at).to be_nil
      expect(featured_tag('alpha').url).to eq('https://remote.example/tags/alpha')

      kept.reload
      expect(kept.statuses_count).to eq(99)
      expect(kept.last_status_at).to eq(Time.utc(2020, 1, 1))
      expect(FeaturedTag.find_by(id: removed.id)).to be_nil

      grouped = queries.select { |sql| sql.include?('GROUP BY "statuses_tags"."tag_id"') && sql.match?(/COUNT/i) }
      individual = queries.select { |sql| sql.match?(/SELECT COUNT\(\*\)/i) && sql.include?('statuses_tags') && sql.exclude?('GROUP BY') }

      expect(grouped.size).to eq(1)
      expect(grouped.first).not_to include('ORDER BY')
      expect(individual).to be_empty
    end
  end

  def items
    %w(kept alpha beta gamma).map do |name|
      { 'type' => 'Hashtag', 'name' => name, 'href' => "https://remote.example/tags/#{name}" }
    end
  end

  def tag_status(tag, visibility: :public, **attrs)
    status = Fabricate(:status, account: account, visibility: visibility, **attrs)
    status.tags << tag
    status
  end

  def featured_tag(name)
    FeaturedTag.joins(:tag).find_by!(account: account, tags: { name: name })
  end

  def featured_count(name)
    featured_tag(name).statuses_count
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      queries << payload[:sql] if payload[:sql].present? && payload[:name] != 'SCHEMA'
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end
end
