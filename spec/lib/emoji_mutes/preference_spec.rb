# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmojiMutes::Preference do
  let(:user) { Fabricate(:user) }

  def mute_body(native = '👍')
    {
      'emoji' => { 'kind' => 'unicode', 'native' => native },
      'effects' => {
        'replace_in_text' => true,
        'reject_reactions_to_own_posts' => true,
        'hide_reactions' => true,
        'hide_in_picker' => true,
      },
    }
  end

  it 'leaves unset users off, enables them on the first save, and does not rewrite an explicit off' do
    preference = described_class.new(user)
    expect(preference.enabled?).to eq(false)
    expect(preference.explicit?).to eq(false)
    expect(preference.modal?).to eq(true)
    expect(preference.effects_enabled?).to eq(false)
    expect(EmojiMutes::RuleSet.for_user(user).hide_any?).to eq(false)

    EmojiMutes::Repository.new(user).create(mute_body)
    EmojiMutes::Store.rule_sets = nil
    expect(described_class.new(user).enabled?).to eq(true)
    expect(described_class.new(user).explicit?).to eq(true)
    expect(user.reload.setting_emoji_mute_enabled).to eq(true)
    expect(Rails.cache.read(Setting.cache_key('emoji_mute_enabled', user))).to eq(true)
    expect(EmojiMutes::RuleSet.for_user(user).rejects_reaction?('kind' => 'unicode', 'native' => '👍')).to eq(true)

    described_class.new(user).update!(false)
    EmojiMutes::Store.rule_sets = nil
    expect(EmojiMute.where(user_id: user.id).count).to eq(1)
    expect(EmojiMutes::RuleSet.for_user(user).hide_any?).to eq(false)
    expect(EmojiMutes::RuleSet.for_user(user).rejects_reaction?('kind' => 'unicode', 'native' => '👍')).to eq(false)

    expect { EmojiMutes::Repository.new(user).create(mute_body('🎉')) }.to raise_error(EmojiMutes::Invalid) { |error|
      expect(error.errors).to eq([{ 'path' => 'emoji_mute_enabled', 'code' => 'reenable_required' }])
    }
    expect(EmojiMute.where(user_id: user.id).count).to eq(1)
    expect(described_class.new(user).enabled?).to eq(false)

    EmojiMutes::Repository.new(user).create(mute_body('🎉').merge('enable' => true))
    expect(described_class.new(user).enabled?).to eq(true)
    expect(EmojiMute.where(user_id: user.id).count).to eq(2)
  end

  it 'rolls the mute and the enablement back together' do
    repo = EmojiMutes::Repository.new(user)
    allow(repo).to receive(:bump!).and_raise(RuntimeError, 'boom')

    expect { repo.create(mute_body) }.to raise_error(RuntimeError, 'boom')
    expect(EmojiMute.where(user_id: user.id)).to be_empty
    expect(described_class.new(user).explicit?).to eq(false)
    expect(user.reload.setting_emoji_mute_enabled).to eq(false)
    expect(Rails.cache.read(Setting.cache_key('emoji_mute_enabled', user))).not_to eq(true)
  end

  it 'does not change the switch when the last rule is deleted' do
    repo = EmojiMutes::Repository.new(user)
    created = repo.create(mute_body)
    id = created.dig('emoji_mute', 'id')
    mute = EmojiMute.find(id)

    repo.destroy(mute, expected_revision: '1', if_match_revision: nil)
    expect(EmojiMute.where(user_id: user.id)).to be_empty
    expect(described_class.new(user).enabled?).to eq(true)
    expect(described_class.new(user).explicit?).to eq(true)
  end

  it 'backfills only users who already have rules and does not overwrite an explicit value' do
    with_rule = Fabricate(:user)
    without_rule = Fabricate(:user)
    explicit_off = Fabricate(:user)
    EmojiMute.create!(user: with_rule, kind: 'unicode', native: '👍', replacement: '◻')
    EmojiMute.create!(user: explicit_off, kind: 'unicode', native: '🎉', replacement: '◻')
    described_class.new(explicit_off).update!(false)

    load Rails.root.join('db/migrate/20261121143000_backfill_emoji_mute_enabled.rb')
    BackfillEmojiMuteEnabled.new.migrate(:up)

    expect(described_class.new(with_rule).enabled?).to eq(true)
    expect(described_class.new(with_rule).explicit?).to eq(true)
    expect(Setting.unscoped.where(thing_type: 'User', thing_id: without_rule.id, var: 'emoji_mute_enabled')).to be_empty
    expect(described_class.new(explicit_off).enabled?).to eq(false)
    expect(Setting.unscoped.where(thing_type: 'User', thing_id: with_rule.id, var: 'emoji_mute_enabled').count).to eq(1)

    BackfillEmojiMuteEnabled.new.migrate(:up)
    expect(Setting.unscoped.where(thing_type: 'User', thing_id: with_rule.id, var: 'emoji_mute_enabled').count).to eq(1)

    BackfillEmojiMuteEnabled.new.migrate(:down)
    expect(described_class.new(with_rule).enabled?).to eq(true)
    expect(described_class.new(explicit_off).enabled?).to eq(false)
  end

  it 'treats a concurrent insert of the same setting as already backfilled' do
    with_rule = Fabricate(:user)
    EmojiMute.create!(user: with_rule, kind: 'unicode', native: '👍', replacement: '◻')
    load Rails.root.join('db/migrate/20261121143000_backfill_emoji_mute_enabled.rb')
    BackfillEmojiMuteEnabled.new.migrate(:up)
    value = ActiveRecord::Base.connection.quote(true.to_yaml)

    expect do
      ActiveRecord::Base.connection.execute(<<~SQL)
        INSERT INTO settings (var, value, thing_type, thing_id, created_at, updated_at)
        VALUES (
          'emoji_mute_enabled',
          #{value},
          'User',
          #{with_rule.id},
          CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP
        )
        ON CONFLICT (thing_type, thing_id, var) DO NOTHING
      SQL
    end.not_to raise_error

    expect(Setting.unscoped.where(thing_type: 'User', thing_id: with_rule.id, var: 'emoji_mute_enabled').count).to eq(1)
  end
end
