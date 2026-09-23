# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::AdminSettings do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  it 'does not change role permissions or highlighted flags when settings are saved' do
    everyone_permissions = UserRole.find(-99).permissions
    owner_highlighted = UserRole.find_by!(name: 'Owner').highlighted
    form = described_class.new
    allow(form).to receive(:valid?).and_return(true)

    expect(form.save).to be true
    expect(UserRole.find(-99).permissions).to eq everyone_permissions
    expect(UserRole.find_by!(name: 'Owner').highlighted).to eq owner_highlighted
    expect(described_class::KEYS).not_to include(:min_invite_role, :show_staff_badge, :show_moderator_badge)
  end
end
