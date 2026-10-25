# frozen_string_literal: true

require 'rails_helper'

describe Settings::ExternalServices::FeedRouteListsController do
  let(:user) { Fabricate(:user, password: '123456789') }
  let(:challenge) { { challenge_passed_at: Time.now.utc } }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

  after do
    Setting.external_bridge_feeds = false
    Setting.external_bridge_feeds_testers = ''
  end

  def create_list(title, session: challenge)
    post :create, params: { list: { title: title } }, session: session, format: :json
  end

  def error_message(code)
    I18n.t("external_bridge.feed_routes.list_errors.#{code}")
  end

  it 'creates a list owned by the signed-in user and leaves feed routes alone' do
    enable_external_bridge_feeds!(user)
    subscription = external_project_for(user, body: 'List article')[:subscription]

    expect { create_list('  Morning   news ') }.to change { List.where(account_id: user.account_id).count }.by(1)

    list = List.find_by!(account_id: user.account_id)
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include('id' => list.id.to_s, 'title' => 'Morning news')
    expect(list.title).to eq 'Morning news'
    expect(ExternalFeedRoute.where(user_id: user.id)).to be_empty
    expect(subscription.reload.feed_routes_revision).to eq 0
  end

  it 'ignores an owner supplied in the request' do
    enable_external_bridge_feeds!(user)
    other = Fabricate(:user)

    post :create, params: { list: { title: 'Mine', account_id: other.account_id }, account_id: other.account_id, user_id: other.id }, session: challenge, format: :json

    expect(response).to have_http_status(:created)
    expect(List.where(account_id: other.account_id)).to be_empty
    expect(List.find_by!(title: 'Mine').account_id).to eq user.account_id
  end

  it 'creates the list for the signed-in user, not for another user on the same account' do
    enable_external_bridge_feeds!(user)
    roommate = share_account_user(user.account)

    create_list('Shared account list')

    expect(List.find_by!(title: 'Shared account list').account_id).to eq user.account_id
    expect(roommate.account_id).to eq user.account_id
    expect(ExternalFeedRoute.where(user_id: [user.id, roommate.id])).to be_empty
  end

  it 'asks for the recent challenge before writing' do
    enable_external_bridge_feeds!(user)

    expect { create_list('Needs challenge', session: {}) }.not_to change(List, :count)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq error_message(:challenge)
  end

  it 'does not create a list when delivery is off or the user is not a tester' do
    expect { create_list('Off') }.not_to change(List, :count)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to eq error_message(:disabled)

    enable_external_bridge_feeds!(Fabricate(:user))
    expect { create_list('Not a tester') }.not_to change(List, :count)
    expect(response).to have_http_status(:forbidden)
  end

  it 'rejects blank, overlong, and duplicate titles' do
    enable_external_bridge_feeds!(user)
    Fabricate(:list, account: user.account, title: 'Taken')

    expect { create_list('   ') }.not_to change(List, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq error_message(:blank)

    expect { create_list('x' * (ExternalServices::CreateFeedRouteList::TITLE_LIMIT + 1)) }.not_to change(List, :count)
    expect(response.parsed_body['error']).to eq error_message(:too_long)

    expect { create_list('taken') }.not_to change(List, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq error_message(:duplicate)
  end

  it 'treats a non-hash list parameter as a blank title' do
    enable_external_bridge_feeds!(user)

    expect { post :create, params: { list: 'Flat' }, session: challenge, format: :json }.not_to change(List, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq error_message(:blank)
  end

  it 'stops at the list limit' do
    enable_external_bridge_feeds!(user)
    now = Time.current
    List.insert_all!(Array.new(List::PER_ACCOUNT_LIMIT) { |index| { account_id: user.account_id, title: "List #{index}", created_at: now, updated_at: now } })

    expect { create_list('One too many') }.not_to change(List, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq error_message(:limit)
  end

  it 'reports a safe failure when the list cannot be saved' do
    enable_external_bridge_feeds!(user)
    allow_any_instance_of(List).to receive(:save).and_return(false) # rubocop:disable RSpec/AnyInstance

    expect { create_list('Broken') }.not_to change(List, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to eq error_message(:failed)
  end

  it 'requires sign in' do
    sign_out :user

    expect { create_list('Anonymous') }.not_to change(List, :count)
    expect(response).to have_http_status(:unauthorized)
  end
end
