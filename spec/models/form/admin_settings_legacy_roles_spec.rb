# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::AdminSettings do
  around do |example|
    previous = {
      min_invite_role: Setting.min_invite_role,
      show_staff_badge: Setting.show_staff_badge,
      show_moderator_badge: Setting.show_moderator_badge,
    }
    example.run
  ensure
    previous.each { |key, value| Setting.public_send("#{key}=", value) }
    Rails.cache.clear
  end

  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  it 'mirrors a saved min_invite_role and badge change onto the default roles' do
    UserRole::LegacySettingsSync.call(min_invite_role: 'admin', show_staff_badge: true, show_moderator_badge: true)

    form = described_class.new(min_invite_role: 'moderator', show_staff_badge: '0', show_moderator_badge: '1')
    allow(form).to receive(:valid?).and_return(true)

    expect(form.save).to be true
    expect(Setting.min_invite_role).to eq 'moderator'
    expect(Setting.show_staff_badge).to be false
    expect(Setting.show_moderator_badge).to be true

    expect(UserRole.find_by!(id: -99).can?(:invite_users)).to be false
    expect(UserRole.find_by!(name: 'Moderator').can?(:invite_users)).to be true
    expect(UserRole.find_by!(name: 'Admin').can?(:invite_users)).to be true
    expect(UserRole.find_by!(name: 'Owner').highlighted).to be false
    expect(UserRole.find_by!(name: 'Admin').highlighted).to be false
    expect(UserRole.find_by!(name: 'Moderator').highlighted).to be true
  end

  it 'raises when the default roles cannot be updated' do
    UserRole.where(name: 'Owner').delete_all
    form = described_class.new(min_invite_role: 'admin', show_staff_badge: '1', show_moderator_badge: '1')
    allow(form).to receive(:valid?).and_return(true)

    expect { form.save }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
