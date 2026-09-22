# frozen_string_literal: true

require 'rails_helper'

describe Settings::Migration::RedirectsController do
  render_views

  let(:user) { Fabricate(:user, password: '12345678') }

  before do
    sign_in user, scope: :user
    allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
  end

  it 'sets a redirect without an action review or a migration row' do
    target = Fabricate(:account)
    expect(MoveService).not_to receive(:new)

    post :create, params: { form_redirect: { acct: target.acct, current_password: '12345678' } }

    expect(response).to redirect_to settings_migration_path
    expect(user.account.reload.moved_to_account_id).to eq target.id
    expect(AccountMigration.count).to eq 0
    expect(ActionReviewRequest.count).to eq 0
  end
end
