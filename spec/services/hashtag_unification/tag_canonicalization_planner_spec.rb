# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe HashtagUnification::TagCanonicalizationPlanner do
  subject(:result) { described_class.new(bucket_count: 4, batch_size: 100, mapping_rows_per_query: 100).call }

  let!(:survivor) { Fabricate(:tag, name: 'blahaj') }
  let!(:loser) { Fabricate(:tag, name: 'BLÅHAJ') }
  let!(:account) { Fabricate(:account) }
  let!(:other_account) { Fabricate(:account) }
  let!(:list) { Fabricate(:list, account: other_account) }
  let!(:status_with_both) { Fabricate(:status) }
  let!(:status_with_loser_only) { Fabricate(:status) }

  before do
    status_with_both.tags << survivor
    status_with_both.tags << loser
    status_with_loser_only.tags << loser

    now = Time.now.utc
    featured_tags = [
      {
        account_id: account.id,
        tag_id: survivor.id,
        statuses_count: 0,
        created_at: now,
        updated_at: now,
      },
      {
        account_id: account.id,
        tag_id: loser.id,
        statuses_count: 0,
        created_at: now,
        updated_at: now,
      },
    ]
    FeaturedTag.insert_all!(featured_tags)

    FollowTag.create!(account: account, tag: survivor, list_id: nil, media_only: false)
    FollowTag.create!(account: account, tag: loser, list_id: nil, media_only: true)
    FollowTag.create!(account: other_account, tag: loser, list: list, media_only: true)
  end

  it 'selects the exact canonical Tag as survivor' do
    expect(result[:collision_groups]).to eq 1
    expect(result[:losing_tags]).to eq 1
    expect(result[:survivor_selection][:exact_canonical]).to eq 1
  end

  it 'separates status rows that can move from rows that must deduplicate' do
    metrics = result[:table_metrics]['statuses_tags']

    expect(metrics[:affected_relationships]).to eq 2
    expect(metrics[:losing_reference_rows]).to eq 2
    expect(metrics[:survivor_already_present_relationships]).to eq 1
    expect(metrics[:rows_requiring_tag_id_change]).to eq 1
    expect(metrics[:rows_to_delete_for_unique_result]).to eq 1
    expect(metrics[:minimum_row_mutations]).to eq 2
  end

  it 'marks affected FeaturedTag relationships for recount' do
    metrics = result[:table_metrics]['featured_tags']

    expect(metrics[:losing_reference_rows]).to eq 1
    expect(metrics[:rows_requiring_tag_id_change]).to eq 0
    expect(metrics[:rows_to_delete_for_unique_result]).to eq 1
    expect(metrics[:recount_relationships]).to eq 1
  end

  it 'keeps destination semantics when planning FollowTag consolidation' do
    metrics = result[:table_metrics]['follow_tags']

    expect(metrics[:affected_relationships]).to eq 2
    expect(metrics[:home_affected_relationships]).to eq 1
    expect(metrics[:list_affected_relationships]).to eq 1
    expect(metrics[:affected_parent_tag_follows]).to eq 2
    expect(metrics[:losing_reference_rows]).to eq 2
    expect(metrics[:rows_requiring_tag_id_change]).to eq 1
    expect(metrics[:rows_to_delete_for_unique_result]).to eq 1
    expect(metrics[:media_only_conflict_relationships]).to eq 1
  end

  it 'does not modify persistent rows' do
    before_tags = Tag.order(:id).pluck(:id, :name)
    before_status_tags = ActiveRecord::Base.connection.select_rows('SELECT status_id, tag_id FROM statuses_tags ORDER BY status_id, tag_id')
    before_follow_tags = FollowTag.order(:id).pluck(:id, :account_id, :tag_id, :list_id, :media_only)

    result

    expect(Tag.order(:id).pluck(:id, :name)).to eq before_tags
    expect(ActiveRecord::Base.connection.select_rows('SELECT status_id, tag_id FROM statuses_tags ORDER BY status_id, tag_id')).to eq before_status_tags
    expect(FollowTag.order(:id).pluck(:id, :account_id, :tag_id, :list_id, :media_only)).to eq before_follow_tags
  end
end
# rubocop:enable Metrics/BlockLength
