# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectoryIndex do
  def directory_group(username, domain: nil, **options)
    local_user = domain.nil? ? Fabricate(:user, confirmed_at: 10.days.ago, approved: true) : nil
    account = Fabricate(:account, {
      username: username,
      domain: domain,
      actor_type: 'Group',
      discoverable: true,
      display_name: options.delete(:display_name) || username,
      note: options.delete(:note) || '',
      user: local_user,
    }.merge(options))
    account.create_account_stat!
    account
  end

  it 'keeps substring search on a bounded ngram and does not use a prefix gram or query_string' do
    analysis = described_class.settings_hash.dig(:settings, :analysis)
    infix = analysis.dig(:tokenizer, :infix_ngram)

    expect(infix).to include(type: 'ngram', min_gram: 2, max_gram: 20)
    expect(analysis[:tokenizer]).not_to have_key(:edge_ngram)
    expect(described_class.settings_hash.dig(:settings, :index, :max_ngram_diff)).to eq(18)
    expect(described_class.infix_window_upper_bound(2_500)).to eq(47_310)
    expect(described_class.infix_window_upper_bound(2_000)).to eq(37_810)
    expect(analysis.dig(:analyzer, :infix, :tokenizer)).to eq('infix_ngram')
    expect(analysis.dig(:analyzer, :infix, :filter)).to eq(%w(lowercase asciifolding cjk_width))
    expect(analysis.dig(:analyzer, :infix_query)).to include(tokenizer: 'keyword', filter: %w(lowercase asciifolding cjk_width))
    expect(analysis.dig(:analyzer, :ja_text, :filter)).to include('sudachi_baseform')
    expect(analysis.dig(:analyzer, :ko_text, :tokenizer)).to eq('nori_user_dict')
    expect(analysis.dig(:analyzer, :zh_text, :tokenizer)).to eq('ik_max_word')
    expect(analysis.dig(:analyzer, :zh_text, :char_filter)).to eq(%w(tsconvert))

    text = described_class.mappings_hash.dig(:mappings, :properties, :text)
    expect(text.dig(:fields, :infix)).to include(analyzer: 'infix', search_analyzer: 'infix_query')
    expect(described_class.mappings_hash.to_s).not_to include('query_string')
    expect(described_class.mappings_hash.to_s).not_to include('wildcard')
  end

  it 'stores the directory fields and leaves private material out of the mapping' do
    properties = described_class.mappings_hash.dig(:mappings, :properties)

    expect(properties.keys.map(&:to_s)).to include(
      'id', 'display_name', 'username', 'acct', 'local_domain_acct', 'domain', 'note', 'text',
      'actor_type', 'listed', 'local', 'software_name', 'software_bucket', 'languages',
      'languages_unset', 'last_status_at'
    )
    expect(properties.keys.map(&:to_s)).not_to include('private_key', 'public_key', 'email', 'fields', 'settings')
    expect(properties[:last_status_at]).to include(type: 'date')
    expect(properties[:id]).to include(type: 'long')
    expect(properties[:domain]).to include(type: 'keyword')
  end

  it 'builds a document from the current group, with null activity left unset' do
    Node.create!(domain: 'lemmy.example', info: { 'software_name' => 'Lemmy', 'languages' => ['ja'] }, nodeinfo: { 'software' => { 'name' => 'lemmy' } })
    local = directory_group('camera', display_name: '写真サークル', note: '<script>alert(1)</script><p>街歩き</p>')
    GroupLanguage.create!(account: local, tag: 'ja')
    remote = directory_group('Walkers', domain: 'lemmy.example', display_name: '100%_done')

    local_document = described_class.compose(local.reload)
    remote_document = described_class.compose(remote.reload)

    expect(local_document.stringify_keys).to include(
      'username' => 'camera',
      'acct' => 'camera',
      'domain' => '',
      'local' => true,
      'software_name' => '',
      'software_bucket' => 'fedibird',
      'languages' => ['ja'],
      'languages_unset' => false,
      'listed' => true,
      'actor_type' => 'Group'
    )
    expect(local_document[:local_domain_acct] || local_document['local_domain_acct']).to eq("camera@#{Rails.configuration.x.local_domain.downcase}")
    note = local_document[:note] || local_document['note']
    expect(note).to eq('街歩き')
    expect(note).not_to include('alert')
    expect(note).not_to include('<')
    expect(local_document.to_s).not_to include('<script')
    expect(local_document.to_s).not_to include('PRIVATE KEY')
    expect(local_document.to_s).not_to include(local.private_key)
    expect(local_document.stringify_keys.fetch('last_status_at')).to be_nil

    expect(remote_document.stringify_keys).to include(
      'username' => 'walkers',
      'acct' => 'walkers@lemmy.example',
      'domain' => 'lemmy.example',
      'local' => false,
      'software_name' => 'lemmy',
      'software_bucket' => 'lemmy',
      'languages' => [],
      'languages_unset' => true
    )
    expect(remote_document[:text] || remote_document['text']).to include('100%_done')
    expect(remote_document[:local_domain_acct] || remote_document['local_domain_acct']).to be_nil
  end
end
