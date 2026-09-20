# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::FollowTagsController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user, account: Fabricate(:account, username: 'alice')) }
  let(:other) { Fabricate(:user, account: Fabricate(:account, username: 'bob')) }

  before do
    sign_in user, scope: :user
    stub_webpacker_manifest
  end

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

  def stub_follow_tag_mirror
    allow(HashtagUnification::FollowTagMirror).to receive(:new)
      .and_raise('U3a mirror must not run for canonical Settings writes')
  end

  def expect_parity_ok
    result = HashtagUnification::FollowTagParity.new.call
    expect(result[:ok]).to eq(true), result.inspect
    expect(result[:management_ready]).to eq(true), result.inspect
  end

  def writer
    HashtagUnification::TagFollowDeliveryWriter.new
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

  describe 'GET #new' do
    it 'renders Form::FollowTag with the follow_tag parameter key' do
      get :new

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag)).to be_a(Form::FollowTag)
      expect(assigns(:follow_tag)).not_to be_persisted
      expect(response.body).to include('follow_tag[name]')
      expect(response.body).to include('follow_tag[list_id]')
      expect(response.body).to include('follow_tag[media_only]')
    end
  end

  describe 'POST #create' do # rubocop:disable Metrics/BlockLength
    it 'creates a Home destination without FollowTag callbacks' do
      stub_follow_tag_mirror

      post :create, params: { follow_tag: { name: 'u3b3dhome', list_id: '', media_only: '1' } }

      delivery = TagFollowDelivery.for_account(user.account).find_by!(list_id: nil)
      shadow = FollowTag.find(delivery.legacy_follow_tag_id)

      expect(response).to redirect_to(settings_follow_tags_path)
      expect(delivery.media_only).to be true
      expect(delivery.name).to eq 'u3b3dhome'
      expect(shadow.list_id).to be_nil
      expect(shadow.media_only).to be true
      get :index
      expect(response.body).to include('u3b3dhome')
      expect_parity_ok
    end

    it 'creates a List destination for an owned list' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')

      post :create, params: { follow_tag: { name: 'u3b3dlist', list_id: list.id, media_only: '0' } }

      delivery = TagFollowDelivery.for_account(user.account).find_by!(list: list)
      expect(delivery.name).to eq 'u3b3dlist'
      expect(FollowTag.find(delivery.legacy_follow_tag_id).list_id).to eq list.id
      expect_parity_ok
    end

    it 'creates or finds a List named from the hashtag when list_id is -1' do
      stub_follow_tag_mirror

      post :create, params: { follow_tag: { name: 'u3b3dnewlist', list_id: '-1' } }

      list = List.find_by!(account: user.account, title: 'u3b3dnewlist')
      delivery = TagFollowDelivery.for_account(user.account).find_by!(list: list)
      expect(delivery.name).to eq 'u3b3dnewlist'
      expect(FollowTag.find(delivery.legacy_follow_tag_id).list_id).to eq list.id
      expect_parity_ok
    end

    it 'does not create a destination for another account\'s List' do
      foreign = Fabricate(:list, account: other.account, title: 'Nope')

      post :create, params: { follow_tag: { name: 'u3b3dsteal', list_id: foreign.id } }

      expect(response).to have_http_status(404)
      expect(TagFollowDelivery.for_account(user.account)).to be_empty
    end

    it 're-renders the form for a duplicate Home' do
      stub_follow_tag_mirror
      post :create, params: { follow_tag: { name: 'u3b3ddup' } }

      expect { post :create, params: { follow_tag: { name: 'u3b3ddup' } } }
        .not_to change(TagFollowDelivery, :count)
      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag).errors).to be_present
      expect_parity_ok
    end
  end

  describe 'GET #edit' do
    it 'populates Form::FollowTag from a canonical-only delivery' do
      tag = Fabricate(:tag, name: 'u3b3deditonly')
      delivery = create_canonical_delivery(account: user.account, tag: tag, media_only: true)

      get :edit, params: { id: delivery.legacy_follow_tag_id }

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag)).to be_a(Form::FollowTag)
      expect(assigns(:follow_tag).id).to eq delivery.legacy_follow_tag_id
      expect(assigns(:follow_tag).name).to eq 'u3b3deditonly'
      expect(assigns(:follow_tag).media_only).to be true
      expect(response.body).to include('u3b3deditonly')
    end

    it 'does not resolve a canonical PK that differs from the compatibility ID' do
      tag = Fabricate(:tag, name: 'u3b3deditpk')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      expect(delivery.id).not_to eq delivery.legacy_follow_tag_id
      get :edit, params: { id: delivery.id }

      expect(response).to have_http_status(404)
    end

    it 'returns not found for a callback-bypassing FollowTag without TagFollowDelivery' do
      source = insert_legacy_follow_tag(account: user.account, tag: Fabricate(:tag, name: 'u3b3deditnone'))

      get :edit, params: { id: source.id }

      expect(response).to have_http_status(404)
    end

    it 'edits a legacy-mirrored FollowTag through the canonical compatibility ID' do
      source = FollowTag.create!(account: user.account, tag: Fabricate(:tag, name: 'u3b3bbridge'))

      get :edit, params: { id: source.id }

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag)).to be_a(Form::FollowTag)
      expect(assigns(:follow_tag).id).to eq source.id
      expect(assigns(:follow_tag).name).to eq 'u3b3bbridge'
    end

    it 'edits an API-created destination through the compatibility ID' do
      delivery = writer.create!(account: user.account, name: 'u3b3csettings')

      get :edit, params: { id: delivery.legacy_resource_id }

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag).id).to eq delivery.legacy_resource_id
      expect(assigns(:follow_tag).name).to eq 'u3b3csettings'
    end
  end

  describe 'PUT #update' do # rubocop:disable Metrics/BlockLength
    it 'updates media_only without FollowTag callbacks' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: user.account, name: 'u3b3dmedia')
      compatibility_id = delivery.legacy_follow_tag_id

      put :update, params: {
        id: compatibility_id,
        follow_tag: { name: 'u3b3dmedia', list_id: '', media_only: '1' },
      }

      expect(response).to redirect_to(settings_follow_tags_path)
      expect(delivery.reload.legacy_follow_tag_id).to eq compatibility_id
      expect(delivery.media_only).to be true
      expect(FollowTag.find(compatibility_id).media_only).to be true
      expect_parity_ok
    end

    it 'moves Home to an owned List and keeps the compatibility ID' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')
      delivery = writer.create!(account: user.account, name: 'u3b3dhomelist')
      compatibility_id = delivery.legacy_follow_tag_id

      put :update, params: {
        id: compatibility_id,
        follow_tag: { name: 'u3b3dhomelist', list_id: list.id },
      }

      expect(delivery.reload.list_id).to eq list.id
      expect(delivery.legacy_follow_tag_id).to eq compatibility_id
      expect(TagFollowDelivery.home.where(tag_follow: delivery.tag_follow)).to be_empty
      expect(FollowTag.find(compatibility_id).list_id).to eq list.id
      expect_parity_ok
    end

    it 'moves List to Home when no Home peer exists' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')
      delivery = writer.create!(account: user.account, name: 'u3b3dlisthome', list: list)
      compatibility_id = delivery.legacy_follow_tag_id

      put :update, params: {
        id: compatibility_id,
        follow_tag: { name: 'u3b3dlisthome', list_id: '' },
      }

      expect(delivery.reload.list_id).to be_nil
      expect(delivery.legacy_follow_tag_id).to eq compatibility_id
      expect(FollowTag.find(compatibility_id).list_id).to be_nil
      expect_parity_ok
    end

    it 'moves List A to List B' do
      stub_follow_tag_mirror
      list_a = Fabricate(:list, account: user.account, title: 'A')
      list_b = Fabricate(:list, account: user.account, title: 'B')
      delivery = writer.create!(account: user.account, name: 'u3b3dlistlist', list: list_a)
      compatibility_id = delivery.legacy_follow_tag_id

      put :update, params: {
        id: compatibility_id,
        follow_tag: { name: 'u3b3dlistlist', list_id: list_b.id },
      }

      expect(delivery.reload.list_id).to eq list_b.id
      expect(delivery.legacy_follow_tag_id).to eq compatibility_id
      expect(FollowTag.find(compatibility_id).list_id).to eq list_b.id
      expect_parity_ok
    end

    it 'rolls back a colliding Home move and keeps the shadow unchanged' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')
      home = writer.create!(account: user.account, name: 'u3b3dcollide')
      listed = writer.create!(account: user.account, name: 'u3b3dcollide', list: list)

      put :update, params: {
        id: listed.legacy_follow_tag_id,
        follow_tag: { name: 'u3b3dcollide', list_id: '' },
      }

      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag).errors).to be_present
      expect(listed.reload.list_id).to eq list.id
      expect(home.reload.list_id).to be_nil
      expect(FollowTag.find(listed.legacy_follow_tag_id).list_id).to eq list.id
      expect_parity_ok
    end

    it 'renames the tag, preserves the compatibility ID, and deletes an empty source relation' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: user.account, name: 'u3b3doldname')
      old_follow_id = delivery.tag_follow_id
      compatibility_id = delivery.legacy_follow_tag_id

      put :update, params: {
        id: compatibility_id,
        follow_tag: { name: 'u3b3dnewname', list_id: '' },
      }

      expect(delivery.reload.name).to eq 'u3b3dnewname'
      expect(delivery.legacy_follow_tag_id).to eq compatibility_id
      expect(TagFollow.where(id: old_follow_id)).to be_empty
      expect(FollowTag.find(compatibility_id).tag.name).to eq 'u3b3dnewname'
      expect_parity_ok
    end

    it 'updates a legacy FollowTag-created destination through the writer' do
      source = FollowTag.create!(account: user.account, tag: Fabricate(:tag, name: 'u3b3dlegacyup'))
      stub_follow_tag_mirror

      put :update, params: {
        id: source.id,
        follow_tag: { name: 'u3b3dlegacynew', list_id: '', media_only: '1' },
      }

      expect(response).to redirect_to(settings_follow_tags_path)
      expect(TagFollowDelivery.find_by!(legacy_follow_tag_id: source.id).name).to eq 'u3b3dlegacynew'
      expect(FollowTag.find(source.id).media_only).to be true
      expect_parity_ok
    end
  end

  describe 'DELETE #destroy' do
    it 'destroys one peer destination and leaves the other intact' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: user.account, title: 'A')
      home = writer.create!(account: user.account, name: 'u3b3dpeers')
      listed = writer.create!(account: user.account, name: 'u3b3dpeers', list: list)

      delete :destroy, params: { id: home.legacy_follow_tag_id }

      expect(response).to redirect_to(settings_follow_tags_path)
      expect(TagFollowDelivery.where(id: home.id)).to be_empty
      expect(FollowTag.where(id: home.legacy_follow_tag_id)).to be_empty
      expect(TagFollowDelivery.find(listed.id).list_id).to eq list.id
      expect_parity_ok
    end

    it 'removes the TagFollow when the final destination is destroyed' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: user.account, name: 'u3b3dfinal')
      tag_follow_id = delivery.tag_follow_id
      compatibility_id = delivery.legacy_follow_tag_id

      delete :destroy, params: { id: compatibility_id }

      expect(TagFollowDelivery.where(id: delivery.id)).to be_empty
      expect(FollowTag.where(id: compatibility_id)).to be_empty
      expect(TagFollow.where(id: tag_follow_id)).to be_empty
      expect_parity_ok
    end

    it 'destroys an API-created destination' do
      delivery = writer.create!(account: user.account, name: 'u3b3dapidel')
      stub_follow_tag_mirror

      delete :destroy, params: { id: delivery.legacy_resource_id }

      expect(TagFollowDelivery.where(legacy_follow_tag_id: delivery.legacy_resource_id)).to be_empty
      expect(FollowTag.where(id: delivery.legacy_resource_id)).to be_empty
      expect_parity_ok
    end
  end

  describe 'fail-closed lookup' do
    it 'does not edit, update, or destroy another account\'s destination' do
      source = FollowTag.create!(account: other.account, tag: Fabricate(:tag, name: 'u3b3diso'))

      get :edit, params: { id: source.id }
      expect(response).to have_http_status(404)

      put :update, params: { id: source.id, follow_tag: { name: 'nope' } }
      expect(response).to have_http_status(404)

      delete :destroy, params: { id: source.id }
      expect(response).to have_http_status(404)
      expect(FollowTag.where(id: source.id)).to exist
    end

    it 'renders canonical edit data but fails closed on mutation when the shadow is missing' do
      tag = Fabricate(:tag, name: 'u3b3dshadowless')
      delivery = create_canonical_delivery(account: user.account, tag: tag)

      get :edit, params: { id: delivery.legacy_follow_tag_id }
      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag).name).to eq 'u3b3dshadowless'

      put :update, params: {
        id: delivery.legacy_follow_tag_id,
        follow_tag: { name: 'u3b3dshadowless', list_id: '', media_only: '1' },
      }
      expect(response).to have_http_status(200)
      expect(assigns(:follow_tag).errors).to be_present
      expect(delivery.reload.media_only).to be false

      delete :destroy, params: { id: delivery.legacy_follow_tag_id }
      expect(response).to have_http_status(422)
      expect(TagFollowDelivery.where(id: delivery.id)).to exist
    end
  end

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end
end
