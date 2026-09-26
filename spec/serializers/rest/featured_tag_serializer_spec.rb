# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::FeaturedTagSerializer do
  include RoutingHelper

  def serialize(featured_tag)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        featured_tag,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'renders statuses_count as a string' do
    featured_tag = FeaturedTag.create!(account: Fabricate(:account), name: 'counted')
    featured_tag.update_column(:statuses_count, 12)

    json = serialize(featured_tag.reload)

    expect(json[:statuses_count]).to eq('12')
    expect(json[:statuses_count]).to be_a(String)
  end

  it 'renders a zero statuses_count as the string 0' do
    featured_tag = FeaturedTag.create!(account: Fabricate(:account), name: 'empty')
    featured_tag.update_column(:statuses_count, 0)

    expect(serialize(featured_tag.reload)[:statuses_count]).to eq('0')
  end

  it 'renders last_status_at as a date' do
    featured_tag = FeaturedTag.create!(account: Fabricate(:account), name: 'dated')
    featured_tag.update_column(:last_status_at, Time.utc(2026, 9, 27, 12, 34, 56))

    expect(serialize(featured_tag.reload)[:last_status_at]).to eq('2026-09-27')
  end

  it 'keeps a nil last_status_at as null' do
    featured_tag = FeaturedTag.create!(account: Fabricate(:account), name: 'undated')
    featured_tag.update_column(:last_status_at, nil)

    json = serialize(featured_tag.reload)

    expect(json).to have_key(:last_status_at)
    expect(json[:last_status_at]).to be_nil
  end

  it 'returns the raw tag name rather than display_name' do
    account = Fabricate(:account)
    tag = Fabricate(:tag, name: 'foo')
    tag.update!(display_name: 'FOO')
    featured_tag = FeaturedTag.create!(account: account, name: 'foo')

    expect(serialize(featured_tag)[:name]).to eq('foo')
  end

  it 'keeps the local featured tag URL on the Fedibird route' do
    account = Fabricate(:account)
    featured_tag = FeaturedTag.create!(account: account, name: 'localtag')

    expect(serialize(featured_tag)[:url]).to eq(short_account_tag_url(account, featured_tag.tag))
  end

  it 'keeps the stored URL for a remote featured tag' do
    remote_account = Fabricate(:account, domain: 'remote.example')
    featured_tag = FeaturedTag.create!(
      account: remote_account,
      name: 'foo',
      url: 'https://remote.example/@alice/tagged/foo'
    )

    expect(serialize(featured_tag)[:url]).to eq('https://remote.example/@alice/tagged/foo')
  end
end
