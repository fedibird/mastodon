# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HashtagUnification::FollowTagAnalyzer do
  subject(:result) { described_class.new(sample_limit: 10).call }

  let!(:account) { Fabricate(:account) }
  let!(:other_account) { Fabricate(:account) }
  let!(:home_and_list_tag) { Fabricate(:tag, name: 'homeandlist') }
  let!(:lists_only_tag) { Fabricate(:tag, name: 'listsonly') }
  let!(:home_only_tag) { Fabricate(:tag, name: 'homeonly') }
  let!(:list_a) { Fabricate(:list, account: account, title: 'A') }
  let!(:list_b) { Fabricate(:list, account: account, title: 'B') }

  before do
    Fabricate(:follow_tag, account: account, tag: home_and_list_tag, list_id: nil, media_only: false)
    Fabricate(:follow_tag, account: account, tag: home_and_list_tag, list: list_a, media_only: true)

    Fabricate(:follow_tag, account: account, tag: lists_only_tag, list: list_a, media_only: false)
    Fabricate(:follow_tag, account: account, tag: lists_only_tag, list: list_b, media_only: true)

    Fabricate(:follow_tag, account: other_account, tag: home_only_tag, list_id: nil, media_only: false)

    FollowTag.insert_all!([
      {
        account_id: other_account.id,
        tag_id: home_only_tag.id,
        list_id: nil,
        media_only: true,
        created_at: Time.now.utc,
        updated_at: Time.now.utc,
      },
    ])
  end

  it 'reports relation shapes without treating lists-only follows as Home follows' do
    shapes = result[:relation_shapes]

    expect(shapes[:distinct_relations]).to eq 3
    expect(shapes[:home_only_relations]).to eq 1
    expect(shapes[:lists_only_relations]).to eq 1
    expect(shapes[:home_and_lists_relations]).to eq 1
    expect(shapes[:multi_list_relations]).to eq 1
    expect(shapes[:max_destinations]).to eq 2
  end

  it 'reports duplicate destinations and conflicting media_only values' do
    duplicates = result[:duplicates]

    expect(duplicates[:duplicate_destination_groups]).to eq 1
    expect(duplicates[:duplicate_extra_rows]).to eq 1
    expect(duplicates[:media_only_conflict_groups]).to eq 1
  end

  it 'reports effective destination-count distribution' do
    expect(result[:delivery_count_distribution]).to contain_exactly(
      { destinations: 1, relations: 1 },
      { destinations: 2, relations: 2 }
    )
  end

  it 'is read-only' do
    expect { result }.to change(FollowTag, :count).by(0)
  end
end
