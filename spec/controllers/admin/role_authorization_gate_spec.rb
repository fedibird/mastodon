# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ActionLogsController, type: :controller do
  it 'serves action logs to a functional owner' do
    sign_in Fabricate(:user, admin: true)
    get :index

    expect(response).to have_http_status(200)
  end

  it 'refuses a disabled owner' do
    user = Fabricate(:user, admin: true)
    user.update_columns(disabled: true)
    sign_in user
    get :index

    expect(response).to redirect_to(edit_user_registration_path)
  end

  it 'refuses an ordinary user' do
    sign_in Fabricate(:user)
    get :index

    expect(response).to have_http_status(403)
  end
end

RSpec.describe Admin::PendingAccountsController, type: :controller do
  it 'serves the queue to a functional owner' do
    sign_in Fabricate(:user, admin: true)
    get :index

    expect(response).to have_http_status(200)
  end

  it 'refuses a disabled owner before rendering' do
    user = Fabricate(:user, admin: true)
    user.update_columns(disabled: true)
    sign_in user
    get :index

    expect(response).to redirect_to(edit_user_registration_path)
  end
end
