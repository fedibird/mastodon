# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPostingContext, type: :model do
  def style_for(user, **attributes)
    user.user_posting_contexts.create!({ name: 'Notes' }.merge(attributes))
  end

  it 'saves, reads, updates, and deletes a style owned by the user' do
    user = Fabricate(:user)
    record = style_for(user, purpose: 'A private note', icon: '📝')

    expect(record.reload.user).to eq(user)
    expect(user.user_posting_contexts).to include(record)

    record.update!(name: 'Renamed')
    expect(record.reload.name).to eq('Renamed')

    expect { record.destroy! }.to change { user.user_posting_contexts.count }.from(1).to(0)
  end

  it 'removes styles when the user is destroyed and cascades in the database' do
    user = Fabricate(:user)
    style_for(user)
    foreign_key = described_class.connection.foreign_keys('user_posting_contexts').find { |key| key.to_table == 'users' }
    account_key = described_class.connection.foreign_keys('user_posting_contexts').find { |key| key.to_table == 'accounts' }

    expect(foreign_key.on_delete).to eq(:cascade)
    expect(account_key.on_delete).to eq(:nullify)
    expect { user.destroy! }.to change(described_class, :count).by(-1)
  end

  it 'allows duplicate names and rejects a blank or oversized name' do
    user = Fabricate(:user)
    style_for(user, name: 'Same')
    expect(style_for(user, name: 'Same')).to be_persisted
    expect(described_class.new(user: user, name: '   ')).not_to be_valid
    expect(described_class.new(user: user, name: 'a' * 81)).not_to be_valid
    expect(described_class.copied_name('Same')).to eq("Same#{I18n.t('user_posting_contexts.copy_suffix')}")
    expect(described_class.copied_name('あ' * 80).length).to eq(80)
  end

  it 'limits each user to 50 styles' do
    user = Fabricate(:user)
    described_class::MAX_PER_USER.times { |index| style_for(user, name: "Style #{index}") }

    extra = user.user_posting_contexts.new(name: 'One more')
    expect(extra).not_to be_valid
    expect(extra.errors[:base].join).to include('50')
  end

  it 'rejects unknown JSON and keeps inheritance distinct from explicit clears' do
    user = Fabricate(:user)
    record = style_for(user)
    record.defaults = { 'nope' => true }
    expect(record).not_to be_valid

    record.defaults = { 'language' => nil }
    expect(record).not_to be_valid

    record.defaults = { 'spoiler' => { 'enabled' => false, 'text' => 'hidden' } }
    expect(record).not_to be_valid

    record.managed = { 'hashtags' => [{ 'name' => 'ruby', 'normalized_name' => 'ruby', 'enforcement' => 'required', 'rule_id' => 'group-follow' }] }
    expect(record).not_to be_valid

    record.defaults = {}
    record.managed = { 'hashtags' => [] }
    expect(record).to be_valid

    record.apply_form(
      'name' => 'Notes',
      'spoiler_choice' => 'disabled',
      'language_choice' => 'auto',
      'visibility_choice' => 'explicit',
      'visibility_value' => 'mutual',
      'sensitive_choice' => 'explicit',
      'sensitive_value' => 'true',
      'hashtags_text' => '#Ruby・ ＃Ｒｕｂｙ fedibird'
    )
    expect(record.save).to be true

    saved = described_class.find(record.id)
    expect(saved.defaults['spoiler']).to eq('enabled' => false)
    expect(saved.defaults['language']).to eq('mode' => 'auto')
    expect(saved.defaults['visibility']).to eq('mutual')
    expect(saved.defaults['sensitive']).to be true
    expect(saved.defaults).not_to have_key('purpose')
    expect(saved.managed['hashtags'].map { |tag| tag['normalized_name'] }).to eq(%w(ruby fedibird))
    expect(saved.managed['hashtags']).to all(include('enforcement' => 'advisory', 'rule_id' => 'user-posting-context'))

    inherited = style_for(user, name: 'Inherited')
    expect(inherited.defaults).not_to have_key('spoiler')
    expect(inherited.defaults).not_to have_key('language')
    expect(inherited.composer_overrides['defaults']).not_to have_key('spoiler')
  end

  it 'accepts a known group and a legal hashtag, and rejects the other shapes' do
    user = Fabricate(:user)
    group = Fabricate(:account, username: 'localsquad', actor_type: 'Group')
    person = Fabricate(:account, username: 'person')

    expect(style_for(user, name: 'Group', target_kind: 'group', target_account: group)).to be_persisted
    expect(style_for(user, name: 'Tag', target_kind: 'hashtag', target_hashtag: '#Ruby・')).to have_attributes(target_hashtag: 'Ruby', target_account_id: nil)
    expect(user.user_posting_contexts.new(name: 'Missing', target_kind: 'group')).not_to be_valid
    expect(user.user_posting_contexts.new(name: 'Person', target_kind: 'group', target_account: person)).not_to be_valid
    expect(user.user_posting_contexts.new(name: 'Bad tag', target_kind: 'hashtag', target_hashtag: '!!!')).not_to be_valid
    expect(user.user_posting_contexts.new(name: 'Bad kind', target_kind: 'list')).not_to be_valid
  end

  it 'does not let a later assignment change the owner or storage version' do
    user = Fabricate(:user)
    other = Fabricate(:user)
    record = style_for(user)
    record.schema_version = 9
    expect(record).not_to be_valid

    record.schema_version = 1
    record.user_id = other.id
    record.name = 'Still mine'
    expect(record.save).to be true
    expect(record.reload.user_id).to eq(user.id)
    expect(record.schema_version).to eq(1)
    expect(record.name).to eq('Still mine')
  end

  it 'raises on a stale lock instead of keeping the second write' do
    user = Fabricate(:user)
    record = style_for(user, name: 'Original')
    stale = described_class.find(record.id)
    record.update!(name: 'First save')

    expect { stale.update!(name: 'Second save') }.to raise_error(ActiveRecord::StaleObjectError)
    expect(record.reload.name).to eq('First save')
  end

  it 'is not consulted by post creation' do
    source = Rails.root.join('app/services/post_status_service.rb').read
    expect(source).not_to include('UserPostingContext')
    user = Fabricate(:user)
    expect { style_for(user) }.not_to change(Status, :count)
  end
end
