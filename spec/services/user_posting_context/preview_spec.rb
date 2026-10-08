# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPostingContext::Preview do
  def style_for(user, **attributes)
    user.user_posting_contexts.create!({ name: 'Notes' }.merge(attributes))
  end

  it 'keeps a local group requirement separate from the style override' do
    user = Fabricate(:user)
    group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
    record = style_for(
      user,
      target_kind: 'group',
      target_account: group,
      defaults: { 'visibility' => 'private' },
      managed: {
        'hashtags' => [
          { 'name' => 'mine', 'normalized_name' => 'mine', 'enforcement' => 'advisory', 'rule_id' => 'user-posting-context' },
        ],
      }
    )

    preview = described_class.build(user: user, context: record)

    expect(preview.visibility.value).to eq('private')
    expect(preview.visibility.source).to eq('explicit')
    expect(preview.visibility.permission).to eq('conflict')
    expect(preview.visibility).not_to be_permitted
    expect(preview.required_rules.map { |rule| rule['kind'] }).to include('mention', 'following')
    expect(preview.required_rules.map { |rule| rule['label'] }).not_to include('mine')
    expect(preview.user_hashtags.map { |tag| tag['name'] }).to eq(['mine'])
    expect(preview.recommended_rules).to be_empty
    expect(record.reload.defaults['visibility']).to eq('private')
  end

  it 'does not treat unsupported or unknown discovery as permission' do
    user = Fabricate(:user)
    remote = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')
    record = style_for(user, target_kind: 'group', target_account: remote, defaults: { 'visibility' => 'public' })

    expect(ResolveAccountService).not_to receive(:new)
    preview = described_class.build(user: user, context: record)

    expect(preview.discovery_status).to eq('unsupported')
    expect(preview.discovery_trust).to eq('unverified')
    expect(preview.visibility).not_to be_permitted
    expect(preview.visibility.permission).to eq('unverified')
    expect(preview.required_rules).to be_empty
    expect(preview.conflicts.map { |item| item['kind'] }).to include('unverified')

    service = instance_double(PostingContext::DiscoveryService)
    allow(PostingContext::DiscoveryService).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_return(status: 'unknown', reason: 'mystery', context: { constraints: { allowed_visibilities: %w(public) } })

    unknown = described_class.build(user: user, context: record)
    expect(unknown.visibility).not_to be_permitted
    expect(unknown.visibility.permission).to eq('unverified')
    expect(unknown.required_rules).to be_empty
  end

  it 'shows an explicit destination recommendation without mixing it into required rules' do
    user = Fabricate(:user)
    group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
    record = style_for(user, target_kind: 'group', target_account: group)
    service = instance_double(PostingContext::DiscoveryService)
    allow(PostingContext::DiscoveryService).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_return(
      status: 'resolved',
      context: {
        managed: {
          hashtags: [
            { name: 'must', normalized_name: 'must', enforcement: 'required', rule_id: 'dest-required' },
            { name: 'tip', normalized_name: 'tip', enforcement: 'recommended', rule_id: 'dest-tip' },
            { name: 'note', normalized_name: 'note', enforcement: 'advisory', rule_id: 'dest-note' },
          ],
        },
        constraints: { allowed_visibilities: %w(public unlisted) },
        recommended: { language: 'ja' },
      }
    )

    preview = described_class.build(user: user, context: record)

    expect(preview.required_rules.map { |rule| rule['label'] }).to eq(['must'])
    expect(preview.recommended_rules.map { |rule| rule['label'] }).to include('tip', 'language: ja')
    expect(preview.visibility.value).to eq(user.setting_default_privacy)
    expect(preview.visibility.permitted?).to eq(%w(public unlisted).include?(preview.visibility.value))
  end

  it 'does not read group discovery for a hashtag or an empty destination' do
    user = Fabricate(:user)
    tagged = style_for(user, target_kind: 'hashtag', target_hashtag: 'ruby')
    plain = style_for(user, target_kind: 'none')

    expect(PostingContext::DiscoveryService).not_to receive(:new)
    tagged_preview = described_class.build(user: user, context: tagged)
    plain_preview = described_class.build(user: user, context: plain)

    expect(tagged_preview.discovery_trust).to eq('not_applicable')
    expect(tagged_preview.visibility).not_to be_permitted
    expect(tagged_preview.destination_hashtag).to include(
      'name' => 'ruby',
      'normalized_name' => 'ruby',
      'enforcement' => 'advisory',
      'origin' => 'destination',
      'rule_id' => 'user-posting-context:destination'
    )
    expect(tagged_preview.recommended_rules).to be_empty
    expect(plain_preview.discovery_reason).to eq('no_target')
    expect(plain_preview.destination_hashtag).to be_nil
    expect(plain_preview.required_rules).to be_empty
    expect(tagged.reload.managed).not_to have_key('hashtags')
  end

  it 'keeps a destination hashtag distinct from a style advisory tag with the same name' do
    user = Fabricate(:user)
    record = style_for(
      user,
      target_kind: 'hashtag',
      target_hashtag: '#Ruby・',
      managed: {
        'hashtags' => [
          { 'name' => 'ruby', 'normalized_name' => 'ruby', 'enforcement' => 'advisory', 'rule_id' => 'user-posting-context' },
        ],
      }
    )

    preview = described_class.build(user: user, context: record)

    expect(preview.destination_hashtag).to include('normalized_name' => 'ruby', 'origin' => 'destination', 'rule_id' => 'user-posting-context:destination')
    expect(preview.user_hashtags.first).to include('normalized_name' => 'ruby', 'origin' => 'style', 'rule_id' => 'user-posting-context')
    expect(record.reload.managed['hashtags'].first.keys).to match_array(%w(name normalized_name enforcement rule_id))
  end

  it 'does not treat a permitted visibility as permission to post in the group' do
    user = Fabricate(:user)
    group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
    record = style_for(user, target_kind: 'group', target_account: group, defaults: { 'visibility' => 'public' })

    preview = described_class.build(user: user, context: record)

    expect(preview.visibility).to be_permitted
    expect(preview.required_rules.map { |rule| rule['kind'] }).to include('following', 'mention')
  end

  it 'labels an omitted content warning as inheritance and an explicit disable as a clear' do
    user = Fabricate(:user)
    inherited = style_for(user, name: 'Inherit')
    cleared = style_for(user, name: 'Clear', defaults: { 'spoiler' => { 'enabled' => false }, 'language' => { 'mode' => 'auto' } })

    inherited_preview = described_class.build(user: user, context: inherited)
    cleared_preview = described_class.build(user: user, context: cleared)

    expect(inherited_preview.spoiler.source).to eq('inherit')
    expect(inherited_preview.language.source).to eq('inherit')
    expect(cleared_preview.spoiler.source).to eq('clear')
    expect(cleared_preview.spoiler.value).to eq('enabled' => false, 'text' => '')
    expect(cleared_preview.language.source).to eq('clear')
    expect(cleared_preview.language.value).to be_nil
  end
end
