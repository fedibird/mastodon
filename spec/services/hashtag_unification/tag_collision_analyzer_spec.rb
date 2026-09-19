# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HashtagUnification::TagCollisionAnalyzer do
  subject(:result) { described_class.new(bucket_count: 4, batch_size: 100, top_limit: 10).call }

  let!(:ascii_blahaj) { Fabricate(:tag, name: 'blahaj') }
  let!(:accented_blahaj) { Fabricate(:tag, name: 'BLÅHAJ') }
  let!(:ascii_synthwave) { Fabricate(:tag, name: 'synthwave') }
  let!(:fullwidth_synthwave) { Fabricate(:tag, name: 'Ｓｙｎｔｈｗａｖｅ') }
  let!(:rename_only) { Fabricate(:tag, name: 'MixedCaseTag') }

  before do
    account = Fabricate(:account)
    FavouriteTag.create!(account: account, tag: accented_blahaj)
  end

  it 'finds HashtagNormalizer-equivalent collision groups' do
    expect(result[:collision_groups]).to eq 2
    expect(result[:tags_in_collisions]).to eq 4
    expect(result[:largest_collision_size]).to eq 2

    canonical_names = result[:largest_collision_groups].map { |group| group[:canonical_name] }
    expect(canonical_names).to contain_exactly('blahaj', 'synthwave')
  end

  it 'counts tags that require canonical renaming even without a collision' do
    expect(result[:requiring_rename]).to be >= 3
    expect(HashtagNormalizer.new.normalize(rename_only.name)).to eq 'mixedcasetag'
  end

  it 'reports Tag-dependent rows touched by collision groups' do
    expect(result[:collision_reference_rows]['favourite_tags']).to eq 1
  end

  it 'does not modify Tag rows' do
    before = Tag.order(:id).pluck(:id, :name, :display_name)

    result

    expect(Tag.order(:id).pluck(:id, :name, :display_name)).to eq before
  end
end
