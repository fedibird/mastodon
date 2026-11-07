# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Published Fedibird JSON-LD vocabularies' do
  LEGACY_NAMESPACE = 'http://fedibird.com/ns#'
  GROUP_NAMESPACE = 'https://fedibird.com/ns/group/v1#'

  def vocabulary(relative_path)
    JSON.parse(File.read(Rails.root.join('public', 'ns', relative_path)))
  end

  def declared_ids(document)
    document.fetch('@graph').map { |term| term.fetch('@id') }
  end

  it 'defines every existing legacy Fedibird context term without changing the HTTP IRIs' do
    published = vocabulary('index.jsonld')
    actual_ids = declared_ids(published)
    context_ids = ContextHelper::CONTEXT_EXTENSION_MAP.each_with_object([]) do |(_key, extension), ids|
      next unless extension['fedibird'] == LEGACY_NAMESPACE

      extension.each do |term, mapping|
        next if term == 'fedibird'

        compact = mapping.is_a?(Hash) ? mapping.fetch('@id') : mapping
        expect(compact).to start_with('fedibird:')
        ids << compact.sub('fedibird:', LEGACY_NAMESPACE)
      end
    end

    expect(actual_ids).to match_array(context_ids)
    expect(actual_ids.uniq).to eq(actual_ids)
    expect(published.fetch('@graph').map { |term| term.fetch('@type') }.uniq).to eq(['rdf:Property'])
    expect(actual_ids).not_to include(a_string_starting_with('https://fedibird.com/ns#'))
  end

  it 'defines exactly the approved Group v1 property and profile with no FEP claim' do
    published = vocabulary('group/v1.jsonld')
    expect(declared_ids(published)).to contain_exactly(
      "#{GROUP_NAMESPACE}protocols",
      "#{GROUP_NAMESPACE}MentionFollowAnnounce"
    )

    terms = published.fetch('@graph').index_by { |term| term.fetch('@id') }
    expect(terms.fetch("#{GROUP_NAMESPACE}protocols").fetch('@type')).to eq('rdf:Property')
    expect(terms.fetch("#{GROUP_NAMESPACE}MentionFollowAnnounce").fetch('@type')).to eq('rdfs:Class')
    expect(terms.fetch("#{GROUP_NAMESPACE}protocols").fetch('comment')).to include('not an authorization grant')
    expect(terms.fetch("#{GROUP_NAMESPACE}MentionFollowAnnounce").fetch('comment')).to include('does not imply FEP-1b12')
  end

  it 'expands locally without loading additional contexts' do
    {
      'index.jsonld' => 'http://fedibird.com/ns#quoteUri',
      'group/v1.jsonld' => "#{GROUP_NAMESPACE}protocols",
    }.each do |file, expected_iri|
      expanded = JSON::LD::API.expand(vocabulary(file))
      expect(expanded.map { |node| node.fetch('@id') }).to include(expected_iri)
    end
  end

  it 'ships human-readable resources alongside canonical JSON-LD documents' do
    expect(File.read(Rails.root.join('public/ns/index.html'))).to include('http://fedibird.com/ns#')
    expect(File.read(Rails.root.join('public/ns/group/v1.html'))).to include("#{GROUP_NAMESPACE}MentionFollowAnnounce")
  end
end
