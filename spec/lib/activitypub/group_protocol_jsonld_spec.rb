# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Group protocol JSON-LD vocabulary v1' do
  it 'expands and compacts the URI-valued protocol set without remote contexts' do
    advertisement = ActivityPub::GroupProtocolAdvertisement
    context = ContextHelper::CONTEXT_EXTENSION_MAP.fetch(:fedibird_group_protocols)
    document = {
      '@context' => context,
      'fedibirdGroupProtocols' => [advertisement::MENTION_FOLLOW_ANNOUNCE_IRI],
    }

    expanded = JSON::LD::API.expand(document)

    expect(expanded.first.fetch(advertisement::PROPERTY_IRI)).to eq(
      [{ '@id' => advertisement::MENTION_FOLLOW_ANNOUNCE_IRI }]
    )
    compacted = JSON::LD::API.compact(expanded, context, expanded: true)
    expect(compacted.fetch('fedibirdGroupProtocols')).to eq([advertisement::MENTION_FOLLOW_ANNOUNCE_IRI])
  end

  it 'keeps the packaged v1 vocabulary aligned with the advertised IRIs' do
    advertisement = ActivityPub::GroupProtocolAdvertisement
    vocabulary = JSON.parse(File.read(Rails.root.join('docs', 'activitypub_group_protocol_v1.jsonld')))
    declared = vocabulary.fetch('@graph').map { |entry| entry.fetch('@id') }

    expect(declared).to contain_exactly(
      advertisement::PROPERTY_IRI,
      advertisement::MENTION_FOLLOW_ANNOUNCE_IRI
    )
  end
end
