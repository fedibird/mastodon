# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::FollowTagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bob')) }

  before { sign_in user, scope: :user }

  def unused_legacy_id
    [
      FollowTag.maximum(:id) || 0,
      TagFollowDelivery.maximum(:id) || 0,
    ].max + 1_000_000
  end

  def insert_legacy_follow_tag(account:, tag:)
    now = Time.now.utc
    FollowTag.insert_all!(
      [
        {
          account_id: account.id,
          tag_id: tag.id,
          list_id: nil,
          media_only: false,
          created_at: now,
          updated_at: now,
        },
      ]
    )
    FollowTag.find_by!(account: account, tag: tag)
  end

  def create_canonical_delivery(account:, tag:, list: nil, media_only: false, legacy_id: unused_legacy_id)
    tag_follow = TagFollow.find_or_create_by!(account: account, tag: tag)
    TagFollowDelivery.create!(
      tag_follow: tag_follow,
      list: list,
      media_only: media_only,
      legacy_follow_tag_id: legacy_id
    )
  end

  describe 'GET #index' do
    it 'lists a canonical-only delivery with edit/delete links using the compatibility ID' do
      tag = Fabricate(:tag, name: 'u3b3bsettings')
      list = Fabricate(:list, account: user.account, title: 'A')
      delivery = create_canonical_delivery(account: user.account, tag: tag, list: list, media_only: true)

      get :index

      expect(response).to have_http_status(200)
      expect(response.body).to include('u3b3bsettings')
      expect(response.body).to include('A')
      expect(response.body).to include(edit_settings_follow_tag_path(delivery.legacy_follow_tag_id))
      expect(response.body).to include(settings_follow_tag_path(delivery.legacy_follow_tag_id))
      expect(response.body).not_to include(edit_settings_follow_tag_path(delivery.id))
      expect(FollowTag.where(account: user.account, tag: tag)).to be_empty
    end

    it 'does not list a callback-bypassing FollowTag without TagFollowDelivery' do
      tag = Fabricate(:tag, name: 'u3b3bhidden')
      insert_legacy_follow_tag(account: user.account, tag: tag)

      get :index

      expect(FollowTag.exists?(account: user.account, tag: tag)).to be true
      expect(response.body).not_to include('u3b3bhidden')
    end

    it 'does not list another account\'s canonical delivery' do
      tag = Fabricate(:tag, name: 'u3b3bforeign')
      create_canonical_delivery(account: other.account, tag: tag)

      get :index

      expect(response.body).not_to include('u3b3bforeign')
    end
  end

  describe 'read/write seam' do
    it 'lists a mirrored FollowTag and still edits it through the legacy resource' do
      tag = Fabricate(:tag, name: 'u3b3bbridge')
      source = FollowTag.create!(account: user.account, tag: tag)
      delivery = TagFollowDelivery.find_by!(legacy_follow_tag_id: source.id)

      get :index

      expect(response.body).to include('u3b3bbridge')
      expect(response.body).to include(edit_settings_follow_tag_path(source.id))
      expect(delivery.legacy_follow_tag_id).to eq source.id

      get :edit, params: { id: source.id }

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag)).to eq source
    end
  end
end
