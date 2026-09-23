# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'development admin role seed' do
  def load_development_seed
    allow(Doorkeeper::Application).to receive(:create!)
    allow(Rails.env).to receive(:development?).and_return(true)
    load Rails.root.join('db', 'seeds.rb')
  end

  it 'creates the development admin as Owner and repairs role_id on a later run' do
    load_development_seed

    domain = Rails.configuration.x.local_domain
    user = User.find_by!(email: "admin@#{domain}")
    owner_id = UserRole.find_by!(name: 'Owner').id

    expect(user).to be_admin
    expect(user).not_to be_moderator
    expect(user.role_id).to eq owner_id
    expect(UserRole.where(name: 'Owner').count).to eq 1
    expect(UserRole.where(id: -99).count).to eq 1

    user.update_columns(role_id: nil)
    load_development_seed

    expect(user.reload.role_id).to eq owner_id
    expect(user).to be_admin
    expect(user).not_to be_moderator
    expect(UserRole.where(name: %w(Moderator Admin Owner)).count).to eq 3
  end
end
