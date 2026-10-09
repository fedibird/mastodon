# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPostingContextAssignment, type: :model do
  def style_for(user, **attributes)
    user.user_posting_contexts.create!({ name: 'Notes' }.merge(attributes))
  end

  def group_account(username = 'localsquad')
    Fabricate(:account, username: username, actor_type: 'Group')
  end

  it 'creates, reads, updates, and deletes an assignment owned by the user' do
    user = Fabricate(:user)
    group = group_account
    style = style_for(user, target_kind: 'group', target_account: group)
    record = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: style)

    expect(record).to be_persisted
    expect(record.user).to eq(user)
    expect(user.user_posting_context_assignments).to include(record)
    expect(record.api_payload).to include(
      status: 'style',
      style_id: style.id.to_s,
      revision: record.lock_version
    )
    expect(record.api_payload[:surface]).to eq(kind: 'group', key: group.id.to_s)

    other = style_for(user, name: 'Common')
    updated = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: other)

    expect(updated.id).to eq(record.id)
    expect(updated.user_posting_context_id).to eq(other.id)
    expect(updated.lock_version).to eq(record.lock_version + 1)

    expect { updated.destroy! }.to change { user.user_posting_context_assignments.count }.from(1).to(0)
  end

  it 'keeps one row per user and surface' do
    user = Fabricate(:user)
    group = group_account
    described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: nil)
    duplicate = described_class.new(user: user, surface_kind: 'group', surface_key: group.id.to_s)

    expect(duplicate).not_to be_valid
    expect do
      described_class.new(user: user, surface_kind: 'group', surface_key: group.id.to_s).save!(validate: false)
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(described_class.where(user: user, surface_kind: 'group', surface_key: group.id.to_s).count).to eq(1)
  end

  it 'lets two users keep different defaults for the same group' do
    group = group_account
    first = Fabricate(:user)
    second = Fabricate(:user)
    style = style_for(first, target_kind: 'group', target_account: group)

    described_class.assign!(user: first, surface_kind: 'group', surface_key: group.id.to_s, style: style)
    described_class.assign!(user: second, surface_kind: 'group', surface_key: group.id.to_s, style: nil)

    expect(described_class.where(surface_kind: 'group', surface_key: group.id.to_s).count).to eq(2)
    expect(second.user_posting_context_assignments.first.user_posting_context_id).to be_nil
  end

  it 'does not change the row when the same value is saved again' do
    user = Fabricate(:user)
    group = group_account
    style = style_for(user, target_kind: 'group', target_account: group)
    first = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: style)
    stamp = first.updated_at

    second = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: style)

    expect(second.lock_version).to eq(first.lock_version)
    expect(second.updated_at).to eq(stamp)
    expect(described_class.where(user: user).count).to eq(1)
  end

  it 'distinguishes unset, none, and style' do
    user = Fabricate(:user)
    group = group_account
    kind, key = described_class.canonicalize!(user, 'group', group.id.to_s)

    expect(described_class.unset_payload(kind, key)).to include(status: 'unset', style_id: nil, revision: nil)

    none = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: nil)

    expect(none.availability_status).to eq('none')
    expect(none.api_payload[:style_id]).to be_nil

    style = style_for(user, target_kind: 'group', target_account: group)
    chosen = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: style)

    expect(chosen.availability_status).to eq('style')
    expect(chosen.api_payload[:style_id]).to eq(style.id.to_s)
  end

  it 'rejects another user’s style' do
    user = Fabricate(:user)
    other = Fabricate(:user)
    group = group_account
    foreign_style = style_for(other, target_kind: 'group', target_account: group)

    expect do
      described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: foreign_style)
    end.to raise_error(described_class::InvalidAssignment)
    expect(user.user_posting_context_assignments).to be_empty
  end

  it 'accepts a group, a normalized hashtag, and a list owned by the user' do
    user = Fabricate(:user)
    group = group_account
    list = Fabricate(:list, account: user.account, title: 'Reading')
    common = style_for(user, name: 'Common')
    tagged = style_for(user, name: 'Books', target_kind: 'hashtag', target_hashtag: 'Foo')

    group_row = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: common)
    tag_row = described_class.assign!(user: user, surface_kind: 'hashtag', surface_key: '#Foo', style: tagged)
    list_row = described_class.assign!(user: user, surface_kind: 'list', surface_key: list.id.to_s, style: common)

    expect(group_row.surface_key).to eq(group.id.to_s)
    expect(tag_row.surface_key).to eq('foo')
    expect(tag_row.availability_status).to eq('style')
    expect(list_row.surface_key).to eq(list.id.to_s)
    expect(list_row.availability_status).to eq('style')
  end

  it 'rejects a list the user does not own and does not turn it into another place' do
    user = Fabricate(:user)
    other = Fabricate(:user)
    foreign_list = Fabricate(:list, account: other.account, title: 'Theirs')
    own_list = Fabricate(:list, account: user.account, title: 'Mine')

    expect do
      described_class.assign!(user: user, surface_kind: 'list', surface_key: foreign_list.id.to_s, style: nil)
    end.to raise_error(described_class::InvalidAssignment)
    expect(described_class.where(surface_key: own_list.id.to_s)).to be_empty
    expect(described_class.where(surface_key: foreign_list.id.to_s)).to be_empty
  end

  it 'rejects a dedicated style aimed at a different place' do
    user = Fabricate(:user)
    group = group_account
    other_group = group_account('othersquad')
    list = Fabricate(:list, account: user.account, title: 'Reading')
    group_style = style_for(user, name: 'Group', target_kind: 'group', target_account: other_group)
    tag_style = style_for(user, name: 'News', target_kind: 'hashtag', target_hashtag: 'News')

    expect do
      described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: group_style)
    end.to raise_error(described_class::InvalidAssignment)
    expect do
      described_class.assign!(user: user, surface_kind: 'hashtag', surface_key: 'foo', style: tag_style)
    end.to raise_error(described_class::InvalidAssignment)
    expect do
      described_class.assign!(user: user, surface_kind: 'list', surface_key: list.id.to_s, style: group_style)
    end.to raise_error(described_class::InvalidAssignment)
    expect(user.user_posting_context_assignments).to be_empty
  end

  it 'rejects an unknown group, a person account, and an invalid hashtag' do
    user = Fabricate(:user)
    person = Fabricate(:account, username: 'person', actor_type: 'Person')

    expect do
      described_class.assign!(user: user, surface_kind: 'group', surface_key: person.id.to_s, style: nil)
    end.to raise_error(described_class::InvalidAssignment)
    expect do
      described_class.assign!(user: user, surface_kind: 'group', surface_key: '999999999', style: nil)
    end.to raise_error(described_class::InvalidAssignment)
    expect do
      described_class.assign!(user: user, surface_kind: 'hashtag', surface_key: 'not a tag', style: nil)
    end.to raise_error(described_class::InvalidAssignment)
    expect(user.user_posting_context_assignments).to be_empty
  end

  it 'nullifies the reference when the style is deleted and does not choose another style' do
    user = Fabricate(:user)
    group = group_account
    chosen = style_for(user, name: 'Chosen', target_kind: 'group', target_account: group)
    style_for(user, name: 'Other', target_kind: 'group', target_account: group)
    record = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: chosen)
    foreign_key = described_class.connection.foreign_keys('user_posting_context_assignments').find { |key| key.to_table == 'user_posting_contexts' }

    expect(foreign_key.on_delete).to eq(:nullify)
    expect { chosen.destroy! }.not_to change(described_class, :count)

    record.reload
    expect(record.user_posting_context_id).to be_nil
    expect(record.availability_status).to eq('none')
    expect(record.api_payload[:style_id]).to be_nil
  end

  it 'reports a disabled or retargeted style as unavailable without choosing a replacement' do
    user = Fabricate(:user)
    group = group_account
    other_group = group_account('othersquad')
    replacement = style_for(user, name: 'Other', target_kind: 'group', target_account: group)
    chosen = style_for(user, name: 'Chosen', target_kind: 'group', target_account: group)
    record = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: chosen)

    chosen.update!(enabled: false)
    record.reload

    expect(record.user_posting_context_id).to eq(chosen.id)
    expect(record.availability_status).to eq('unavailable')
    expect(record.api_payload[:style_id]).to eq(chosen.id.to_s)
    expect(record.api_payload[:style_id]).not_to eq(replacement.id.to_s)

    chosen.update!(enabled: true, target_account: other_group)
    record.reload

    expect(record.availability_status).to eq('unavailable')
    expect(record.user_posting_context_id).to eq(chosen.id)
  end

  it 'removes assignments when the user is destroyed and cascades in the database' do
    user = Fabricate(:user)
    group = group_account
    described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: nil)
    foreign_key = described_class.connection.foreign_keys('user_posting_context_assignments').find { |key| key.to_table == 'users' }

    expect(foreign_key.on_delete).to eq(:cascade)
    expect { user.destroy! }.to change(described_class, :count).by(-1)
  end

  it 'updates the row that won a concurrent insert' do
    user = Fabricate(:user)
    group = group_account
    style = style_for(user, target_kind: 'group', target_account: group)
    described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: nil)
    relation = user.user_posting_context_assignments
    allow(user).to receive(:user_posting_context_assignments).and_return(relation)
    finds = 0
    allow(relation).to receive(:find_by).and_wrap_original do |method, *args, **kwargs|
      finds += 1
      finds == 1 ? nil : method.call(*args, **kwargs)
    end
    creates = 0
    allow(relation).to receive(:create!).and_wrap_original do |method, *args, **kwargs|
      creates += 1
      raise ActiveRecord::RecordNotUnique, 'duplicate key' if creates == 1

      method.call(*args, **kwargs)
    end

    result = described_class.assign!(user: user, surface_kind: 'group', surface_key: group.id.to_s, style: style)

    expect(described_class.where(user: user, surface_kind: 'group', surface_key: group.id.to_s).count).to eq(1)
    expect(result.reload.user_posting_context_id).to eq(style.id)
    expect(finds).to be >= 2
  end
end
