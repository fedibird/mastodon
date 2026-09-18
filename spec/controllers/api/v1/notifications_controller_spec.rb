require 'rails_helper'

RSpec.describe Api::V1::NotificationsController, type: :controller do
  render_views

  let(:user)  { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bob')) }
  let(:third) { Fabricate(:user, account: Fabricate(:account, username: 'carol')) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #show' do
    let(:scopes) { 'read:notifications' }

    it 'returns http success' do
      notification = Fabricate(:notification, account: user.account)
      get :show, params: { id: notification.id }

      expect(response).to have_http_status(200)
    end
  end

  describe 'POST #dismiss' do
    let(:scopes) { 'write:notifications' }

    it 'destroys the notification' do
      notification = Fabricate(:notification, account: user.account)
      post :dismiss, params: { id: notification.id }

      expect(response).to have_http_status(200)
      expect { notification.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe 'POST #clear' do
    let(:scopes) { 'write:notifications' }

    it 'clears notifications for the account' do
      notification = Fabricate(:notification, account: user.account)
      post :clear

      expect(notification.account.reload.notifications).to be_empty
      expect(response).to have_http_status(200)
    end
  end

  describe 'GET #index' do
    let(:scopes) { 'read:notifications' }

    before do
      first_status = PostStatusService.new.call(user.account, text: 'Test')
      @reblog_of_first_status = ReblogService.new.call(other.account, first_status)
      mentioning_status = PostStatusService.new.call(other.account, text: 'Hello @alice')
      @mention_from_status = mentioning_status.mentions.first
      @favourite = FavouriteService.new.call(other.account, first_status)
      @second_favourite = FavouriteService.new.call(third.account, first_status)
      @follow = FollowService.new.call(other.account, user.account)
    end

    describe 'with no options' do
      before do
        get :index
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'includes reblog' do
        expect(assigns(:notifications).map(&:activity)).to include(@reblog_of_first_status)
      end

      it 'includes mention' do
        expect(assigns(:notifications).map(&:activity)).to include(@mention_from_status)
      end

      it 'includes favourite' do
        expect(assigns(:notifications).map(&:activity)).to include(@favourite)
      end

      it 'includes follow' do
        expect(assigns(:notifications).map(&:activity)).to include(@follow)
      end
    end

    describe 'from specified user' do
      before do
        get :index, params: { account_id: third.account.id }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'includes favourite' do
        expect(assigns(:notifications).map(&:activity)).to include(@second_favourite)
      end

      it 'excludes favourite' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@favourite)
      end

      it 'excludes mention' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@mention_from_status)
      end

      it 'excludes reblog' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@reblog_of_first_status)
      end

      it 'excludes follow' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@follow)
      end
    end

    describe 'from nonexistent user' do
      before do
        get :index, params: { account_id: 'foo' }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'excludes favourite' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@favourite)
      end

      it 'excludes second favourite' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@second_favourite)
      end

      it 'excludes mention' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@mention_from_status)
      end

      it 'excludes reblog' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@reblog_of_first_status)
      end

      it 'excludes follow' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@follow)
      end
    end

    describe 'with excluded mentions' do
      before do
        get :index, params: { exclude_types: ['mention'] }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'includes reblog' do
        expect(assigns(:notifications).map(&:activity)).to include(@reblog_of_first_status)
      end

      it 'excludes mention' do
        expect(assigns(:notifications).map(&:activity)).to_not include(@mention_from_status)
      end

      it 'includes favourite' do
        expect(assigns(:notifications).map(&:activity)).to include(@favourite)
      end

      it 'includes third favourite' do
        expect(assigns(:notifications).map(&:activity)).to include(@second_favourite)
      end

      it 'includes follow' do
        expect(assigns(:notifications).map(&:activity)).to include(@follow)
      end
    end

    describe 'with types mention' do
      before do
        get :index, params: { types: %w(mention) }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'returns only mention notifications' do
        json = body_as_json
        expect(json).to_not be_empty
        expect(json.map { |notification| notification[:type] }).to all(eq('mention'))
      end
    end

    describe 'with types mention and favourite' do
      before do
        get :index, params: { types: %w(mention favourite) }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'includes mention and favourite and excludes other types' do
        json = body_as_json
        types = json.map { |notification| notification[:type] }

        expect(types).to include('mention', 'favourite')
        expect(types).to_not include('follow', 'reblog')
      end
    end

    describe 'with types and exclude_types' do
      before do
        get :index, params: { types: %w(mention favourite), exclude_types: %w(mention) }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'lets exclude_types win over types' do
        json = body_as_json
        types = json.map { |notification| notification[:type] }

        expect(types).to include('favourite')
        expect(types).to_not include('mention')
      end
    end

    describe 'with unknown types' do
      it 'returns an empty array for an unknown type' do
        get :index, params: { types: %w(not_a_real_notification_type) }

        expect(response).to have_http_status(200)
        expect(body_as_json).to eq []
      end

      it 'ignores unknown types mixed with a known type' do
        get :index, params: { types: %w(mention not_a_real_notification_type) }

        json = body_as_json
        expect(response).to have_http_status(200)
        expect(json).to_not be_empty
        expect(json.map { |notification| notification[:type] }).to all(eq('mention'))
      end
    end

    describe 'from specified user with types favourite' do
      before do
        get :index, params: { types: %w(favourite), account_id: third.account.id }
      end

      it 'returns http success' do
        expect(response).to have_http_status(200)
      end

      it 'returns only favourites from that account' do
        json = body_as_json
        expect(json).to_not be_empty
        expect(json.map { |notification| notification[:type] }).to all(eq('favourite'))
        expect(assigns(:notifications).map(&:activity)).to include(@second_favourite)
        expect(assigns(:notifications).map(&:activity)).to_not include(@favourite)
      end
    end

    describe 'pagination links' do
      it 'keeps types, exclude_types, and account_id in pagination links' do
        get :index, params: {
          types: %w(mention favourite),
          exclude_types: %w(mention),
          account_id: third.account.id,
          limit: 1,
        }

        expect(response).to have_http_status(200)
        expect(response.headers['Link']).to be_present

        link = CGI.unescape(response.headers['Link'].to_s)
        expect(link).to include('types[]=favourite')
        expect(link).to include('exclude_types[]=mention')
        expect(link).to include("account_id=#{third.account.id}")
      end
    end

    context 'with more than the default limit of notifications' do
      before do
        41.times do
          Fabricate(:notification, account: user.account, activity: Fabricate(:favourite), type: :favourite)
        end
      end

      it 'returns at most 40 notifications when limit is omitted' do
        get :index

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq 40
      end

      it 'respects an explicit limit' do
        get :index, params: { limit: 10 }

        expect(response).to have_http_status(200)
        expect(body_as_json.size).to eq 10
      end
    end

    describe 'with types emoji_reaction when reactions are disabled' do
      before do
        user.settings['enable_reaction'] = false
        status = Fabricate(:status, account: user.account)
        emoji_reaction = EmojiReaction.create!(account: other.account, status: status, name: '😂')
        Fabricate(:notification, account: user.account, activity: emoji_reaction, type: :emoji_reaction)

        get :index, params: { types: %w(emoji_reaction) }
      end

      it 'does not let types bypass the reaction setting' do
        expect(response).to have_http_status(200)
        expect(body_as_json).to eq []
      end
    end

    describe 'with types emoji_reaction for a compatibility client' do
      let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes, application: Fabricate(:application, name: 'Tusky')) }

      before do
        status = Fabricate(:status, account: user.account)
        emoji_reaction = EmojiReaction.create!(account: other.account, status: status, name: '😂')
        Fabricate(:notification, account: user.account, activity: emoji_reaction, type: :emoji_reaction)

        get :index, params: { types: %w(emoji_reaction) }
      end

      it 'does not let types bypass client compatibility exclusions' do
        expect(response).to have_http_status(200)
        expect(body_as_json).to eq []
      end
    end
  end
end
