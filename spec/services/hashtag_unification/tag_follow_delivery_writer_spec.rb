# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HashtagUnification::TagFollowDeliveryWriter, type: :service do # rubocop:disable Metrics/BlockLength
  let(:account) { Fabricate(:account) }
  let(:other) { Fabricate(:account) }
  let(:writer) { described_class.new }

  def expect_parity_ok
    result = HashtagUnification::FollowTagParity.new.call
    expect(result[:ok]).to eq(true), result.inspect
    expect(result[:management_ready]).to eq(true), result.inspect
  end

  def stub_follow_tag_mirror
    allow(HashtagUnification::FollowTagMirror).to receive(:new)
      .and_raise('U3a mirror must not run for canonical API writes')
  end

  def shadow_row(id)
    FollowTag.find(id)
  end

  describe '#create!' do
    it 'creates a Home delivery, shadow row, and compatibility ID without FollowTag callbacks' do
      stub_follow_tag_mirror

      delivery = writer.create!(account: account, name: 'u3b3chome', media_only: true)
      shadow = shadow_row(delivery.legacy_follow_tag_id)

      expect(delivery).to be_a(TagFollowDelivery)
      expect(delivery.list_id).to be_nil
      expect(delivery.media_only).to be true
      expect(delivery.name).to eq 'u3b3chome'
      expect(delivery.legacy_follow_tag_id).to eq shadow.id
      expect(delivery.id).not_to eq shadow.id
      expect(TagFollow.find_by!(account: account, tag: delivery.tag)).to eq delivery.tag_follow
      expect(shadow.account_id).to eq account.id
      expect(shadow.tag_id).to eq delivery.tag_id
      expect(shadow.list_id).to be_nil
      expect(shadow.media_only).to be true
      expect_parity_ok
    end

    it 'adds Home to an existing lists-only relation without deleting the List destination' do
      list = Fabricate(:list, account: account, title: 'A')
      list_source = FollowTag.create!(account: account, tag: Fabricate(:tag, name: 'u3b3clistonly'), list: list)
      stub_follow_tag_mirror

      home = writer.create!(account: account, name: 'u3b3clistonly')
      tag_follow = TagFollow.find_by!(account: account, tag: home.tag)

      expect(tag_follow.deliveries.home).to contain_exactly(home)
      expect(tag_follow.deliveries.list.map(&:list_id)).to contain_exactly(list.id)
      expect(FollowTag.where(id: list_source.id)).to exist
      expect(FollowTag.where(id: home.legacy_follow_tag_id)).to exist
      expect_parity_ok
    end

    it 'rejects a duplicate Home without creating extra rows' do
      stub_follow_tag_mirror
      writer.create!(account: account, name: 'u3b3cdup')

      expect { writer.create!(account: account, name: 'u3b3cdup') }.to raise_error(ActiveRecord::RecordInvalid)
      expect(TagFollowDelivery.for_account(account).count).to eq 1
      expect(FollowTag.where(account: account).count).to eq 1
      expect_parity_ok
    end

    it 'creates a List destination for later Settings reuse' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'B')

      delivery = writer.create!(account: account, name: 'u3b3clist', list: list, media_only: 'true')

      expect(delivery.list_id).to eq list.id
      expect(delivery.media_only).to be true
      expect(delivery.tag_follow.deliveries.home).to be_empty
      expect(shadow_row(delivery.legacy_follow_tag_id).list_id).to eq list.id
      expect_parity_ok
    end
  end

  describe '#update!' do
    it 'updates media_only while preserving the compatibility ID' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: account, name: 'u3b3cmedia')
      compatibility_id = delivery.legacy_follow_tag_id

      updated = writer.update!(account: account, legacy_resource_id: compatibility_id, media_only: true)

      expect(updated.id).to eq delivery.id
      expect(updated.legacy_follow_tag_id).to eq compatibility_id
      expect(updated.media_only).to be true
      expect(shadow_row(compatibility_id).media_only).to be true
      expect_parity_ok
    end

    it 'moves one destination to a new tag and deletes an empty source relation' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: account, name: 'u3b3coldtag')
      old_follow_id = delivery.tag_follow_id
      compatibility_id = delivery.legacy_follow_tag_id

      updated = writer.update!(account: account, legacy_resource_id: compatibility_id, name: 'u3b3cnewtag')

      expect(updated.legacy_follow_tag_id).to eq compatibility_id
      expect(updated.name).to eq 'u3b3cnewtag'
      expect(TagFollow.where(id: old_follow_id)).to be_empty
      expect(updated.tag_follow.tag.name).to eq 'u3b3cnewtag'
      expect(shadow_row(compatibility_id).tag_id).to eq updated.tag_id
      expect_parity_ok
    end

    it 'keeps the old TagFollow when another destination remains after a name change' do
      list = Fabricate(:list, account: account, title: 'A')
      tag = Fabricate(:tag, name: 'u3b3ckeepold')
      FollowTag.create!(account: account, tag: tag, list: list)
      stub_follow_tag_mirror
      home = writer.create!(account: account, name: 'u3b3ckeepold')
      old_follow_id = home.tag_follow_id

      writer.update!(account: account, legacy_resource_id: home.legacy_follow_tag_id, name: 'u3b3cmovedpeer')

      expect(TagFollow.where(id: old_follow_id)).to exist
      expect(TagFollow.find(old_follow_id).deliveries.list.count).to eq 1
      expect(TagFollow.find(old_follow_id).deliveries.home).to be_empty
      expect_parity_ok
    end

    it 'rolls back a colliding destination move' do
      stub_follow_tag_mirror
      first = writer.create!(account: account, name: 'u3b3ccollidea')
      second = writer.create!(account: account, name: 'u3b3ccollideb')

      expect do
        writer.update!(account: account, legacy_resource_id: first.legacy_follow_tag_id, name: 'u3b3ccollideb')
      end.to raise_error(ActiveRecord::RecordInvalid)

      expect(first.reload.tag.name).to eq 'u3b3ccollidea'
      expect(second.reload.tag.name).to eq 'u3b3ccollideb'
      expect(shadow_row(first.legacy_follow_tag_id).tag_id).to eq first.tag_id
      expect_parity_ok
    end

    it 'updates a legacy FollowTag-created destination and keeps the shadow synchronized' do
      source = FollowTag.create!(account: account, tag: Fabricate(:tag, name: 'u3b3clegacyup'))
      stub_follow_tag_mirror

      updated = writer.update!(account: account, legacy_resource_id: source.id, name: 'u3b3clegacynew', media_only: true)

      expect(updated.legacy_follow_tag_id).to eq source.id
      expect(updated.name).to eq 'u3b3clegacynew'
      expect(updated.media_only).to be true
      expect(shadow_row(source.id).tag.name).to eq 'u3b3clegacynew'
      expect(shadow_row(source.id).media_only).to be true
      expect_parity_ok
    end
  end

  describe '#destroy!' do
    it 'destroys one peer destination and leaves the other relation/shadow intact' do
      list = Fabricate(:list, account: account, title: 'A')
      stub_follow_tag_mirror
      home = writer.create!(account: account, name: 'u3b3cpeers')
      list_delivery = writer.create!(account: account, name: 'u3b3cpeers', list: list)
      tag_follow_id = home.tag_follow_id

      writer.destroy!(account: account, legacy_resource_id: home.legacy_follow_tag_id)

      expect(TagFollowDelivery.where(id: home.id)).to be_empty
      expect(FollowTag.where(id: home.legacy_follow_tag_id)).to be_empty
      expect(TagFollowDelivery.find(list_delivery.id).list_id).to eq list.id
      expect(FollowTag.where(id: list_delivery.legacy_follow_tag_id)).to exist
      expect(TagFollow.where(id: tag_follow_id)).to exist
      expect_parity_ok
    end

    it 'removes the TagFollow when the final destination is destroyed' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: account, name: 'u3b3cfinal')
      tag_follow_id = delivery.tag_follow_id
      compatibility_id = delivery.legacy_follow_tag_id

      writer.destroy!(account: account, legacy_resource_id: compatibility_id)

      expect(TagFollowDelivery.where(id: delivery.id)).to be_empty
      expect(FollowTag.where(id: compatibility_id)).to be_empty
      expect(TagFollow.where(id: tag_follow_id)).to be_empty
      expect_parity_ok
    end
  end

  describe 'fail-closed lookup' do
    def unused_legacy_id
      [
        FollowTag.maximum(:id) || 0,
        TagFollowDelivery.maximum(:id) || 0,
      ].max + 1_000_000
    end

    it 'does not mutate another account\'s destination' do
      stub_follow_tag_mirror
      delivery = writer.create!(account: other, name: 'u3b3cforeign')

      expect do
        writer.update!(account: account, legacy_resource_id: delivery.legacy_follow_tag_id, media_only: true)
      end.to raise_error(ActiveRecord::RecordNotFound)
      expect do
        writer.destroy!(account: account, legacy_resource_id: delivery.legacy_follow_tag_id)
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(delivery.reload.media_only).to be false
      expect(TagFollowDelivery.where(id: delivery.id)).to exist
    end

    it 'fails closed when the rollback shadow is missing' do
      tag = Fabricate(:tag, name: 'u3b3cshadowless')
      tag_follow = TagFollow.create!(account: account, tag: tag)
      legacy_id = unused_legacy_id
      delivery = TagFollowDelivery.create!(tag_follow: tag_follow, legacy_follow_tag_id: legacy_id)

      expect do
        writer.update!(account: account, legacy_resource_id: legacy_id, media_only: true)
      end.to raise_error(described_class::InconsistentLegacyShadowError)
      expect do
        writer.destroy!(account: account, legacy_resource_id: legacy_id)
      end.to raise_error(described_class::InconsistentLegacyShadowError)

      expect(delivery.reload.media_only).to be false
      expect(TagFollowDelivery.where(id: delivery.id)).to exist
      expect(TagFollow.where(id: tag_follow.id)).to exist
    end
  end
end
