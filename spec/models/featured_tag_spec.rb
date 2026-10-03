require 'rails_helper'

RSpec.describe FeaturedTag, type: :model do
  describe '#reset_data' do
    let(:account) { Fabricate(:account) }
    let(:tag) { Fabricate(:tag, name: 'cats') }
    let(:other_tag) { Fabricate(:tag, name: 'dogs') }

    it 'counts a public status with the matching tag and uses it as last_status_at' do
      status = tag_status

      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(1)
      expect(featured_tag.last_status_at).to eq(status.reload.created_at)
    end

    it 'includes unlisted statuses' do
      tag_status(visibility: :public)
      unlisted = tag_status(visibility: :unlisted)

      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(2)
      expect(featured_tag.last_status_at).to eq(unlisted.reload.created_at)
    end

    it 'excludes private statuses' do
      public_status = tag_status(visibility: :public)
      tag_status(visibility: :private, created_at: 1.minute.from_now)

      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(1)
      expect(featured_tag.last_status_at).to eq(public_status.reload.created_at)
    end

    it 'excludes statuses that only have another tag' do
      matching = tag_status
      tag_status(status_tag: other_tag, created_at: 1.minute.from_now)

      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(1)
      expect(featured_tag.last_status_at).to eq(matching.reload.created_at)
    end

    it 'excludes deleted and expired statuses' do
      visible = tag_status
      deleted = tag_status(created_at: 1.minute.from_now)
      expired = tag_status(created_at: 2.minutes.from_now)
      deleted.discard
      expired.update_column(:expired_at, Time.now.utc)

      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(1)
      expect(featured_tag.last_status_at).to eq(visible.reload.created_at)
    end

    it 'stores a zero count and nil timestamp when nothing matches' do
      featured_tag = create_featured_tag

      expect(featured_tag.statuses_count).to eq(0)
      expect(featured_tag.last_status_at).to be_nil
    end

    it 'uses the highest status id even when its created_at is older' do
      lower_id = tag_status
      higher_id = tag_status
      lower_id.update_columns(created_at: Time.utc(2026, 10, 4, 12, 0, 0))
      higher_id.update_columns(created_at: Time.utc(2026, 1, 1, 8, 0, 0))

      featured_tag = create_featured_tag

      expect(higher_id.id).to be > lower_id.id
      expect(featured_tag.statuses_count).to eq(2)
      expect(featured_tag.last_status_at).to eq(higher_id.reload.created_at)
    end

    it 'recounts to the same statuses_count and last_status_at' do
      lower_id = tag_status
      higher_id = tag_status
      lower_id.update_columns(created_at: Time.utc(2026, 10, 4, 12, 0, 0))
      higher_id.update_columns(created_at: Time.utc(2026, 1, 1, 8, 0, 0))
      featured_tag = create_featured_tag
      featured_tag.update_columns(statuses_count: 99, last_status_at: Time.utc(2020, 1, 1))

      featured_tag.recount

      expect(featured_tag.reload.statuses_count).to eq(2)
      expect(featured_tag.last_status_at).to eq(higher_id.reload.created_at)
    end

    it 'probes tag membership with a correlated scalar subquery' do
      sql = create_featured_tag.send(:matching_statuses).to_sql

      expect(sql).to include('SELECT TRUE')
      expect(sql).to include('statuses_tags.status_id = statuses.id')
      expect(sql).not_to include('INNER JOIN "statuses_tags"')
    end
  end

  def create_featured_tag
    FeaturedTag.create!(account: account, name: tag.name)
  end

  def tag_status(visibility: :public, status_tag: tag, **attrs)
    status = Fabricate(:status, account: account, visibility: visibility, **attrs)
    status.tags << status_tag
    status
  end
end
