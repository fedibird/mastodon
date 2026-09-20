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

  def unused_legacy_id
    [
      FollowTag.maximum(:id) || 0,
      TagFollowDelivery.maximum(:id) || 0,
    ].max + 1_000_000
  end

  def insert_legacy_follow_tag(account:, tag:, list: nil, media_only: false)
    now = Time.now.utc
    FollowTag.insert_all!(
      [
        {
          account_id: account.id,
          tag_id: tag.id,
          list_id: list&.id,
          media_only: media_only,
          created_at: now,
          updated_at: now,
        },
      ]
    )
    scope = FollowTag.where(account: account, tag: tag, media_only: media_only)
    list.nil? ? scope.find_by!(list_id: nil) : scope.find_by!(list_id: list.id)
  end

  def relation_counts(account, tag)
    {
      tag_follows: TagFollow.where(account: account, tag: tag).count,
      deliveries: TagFollowDelivery.for_account(account).for_tags(tag).count,
      shadows: FollowTag.where(account: account, tag: tag).count,
    }
  end

  def follow_rate_limit_count(account)
    key = RateLimiter.new(account, family: :follows).send(:key)
    RedisConfiguration.with { |redis| redis.get(key).to_i }
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

  describe '#update!' do # rubocop:disable Metrics/BlockLength
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

  describe '#standard_follow!' do
    it 'creates a TagFollow, explicit Home delivery, and matching shadow' do
      stub_follow_tag_mirror
      tag = Fabricate(:tag, name: 'u3b3efresh')

      returned = writer.standard_follow!(account: account, tag: tag, rate_limit: true)
      tag_follow = TagFollow.find_by!(account: account, tag: tag)
      home = tag_follow.deliveries.home.first
      shadow = shadow_row(home.legacy_follow_tag_id)

      expect(returned).to eq tag
      expect(tag_follow.deliveries.count).to eq 1
      expect(home.list_id).to be_nil
      expect(home.media_only).to be false
      expect(home.legacy_follow_tag_id).to eq shadow.id
      expect(shadow.account_id).to eq account.id
      expect(shadow.tag_id).to eq tag.id
      expect(shadow.list_id).to be_nil
      expect(shadow.media_only).to be false
      expect(FollowTag.where(account: account, tag: tag).count).to eq 1
      expect_parity_ok
    end

    it 'does not depend on FollowTagMirror for a fresh follow' do
      stub_follow_tag_mirror
      tag = Fabricate(:tag, name: 'u3b3enomirror')

      writer.standard_follow!(account: account, tag: tag)

      expect(TagFollow.exists?(account: account, tag: tag)).to be true
      expect(TagFollowDelivery.for_account(account).for_tags(tag).home.count).to eq 1
      expect_parity_ok
    end

    it 'persists an unsaved valid Tag and returns that record' do
      stub_follow_tag_mirror
      tag = Tag.new(name: 'u3b3eunsaved')

      returned = writer.standard_follow!(account: account, tag: tag)

      expect(returned).to be_persisted
      expect(returned.name).to eq 'u3b3eunsaved'
      expect(TagFollow.exists?(account: account, tag: returned)).to be true
      expect_parity_ok
    end

    it 'is idempotent when Home already exists' do
      stub_follow_tag_mirror
      tag = Fabricate(:tag, name: 'u3b3eidemp')
      writer.standard_follow!(account: account, tag: tag)
      home = TagFollow.find_by!(account: account, tag: tag).deliveries.home.first
      home.update!(media_only: true)
      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).update_all(media_only: true)

      writer.standard_follow!(account: account, tag: tag)

      tag_follow = TagFollow.find_by!(account: account, tag: tag)
      expect(tag_follow.deliveries.count).to eq 1
      expect(tag_follow.deliveries.home.first.id).to eq home.id
      expect(tag_follow.deliveries.home.first.media_only).to be true
      expect(FollowTag.where(account: account, tag: tag).count).to eq 1
      expect(shadow_row(home.legacy_follow_tag_id).media_only).to be true
      expect_parity_ok
    end

    it 'adds Home to a one-List relation and preserves the List destination' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'A')
      listed = writer.create!(account: account, name: 'u3b3elistone', list: list, media_only: true)

      writer.standard_follow!(account: account, tag: listed.tag)

      tag_follow = TagFollow.find_by!(account: account, tag: listed.tag)
      home = tag_follow.deliveries.home.first
      expect(tag_follow.deliveries.count).to eq 2
      expect(home).to be_present
      expect(home.legacy_follow_tag_id).to be_present
      expect(FollowTag.where(id: home.legacy_follow_tag_id)).to exist
      expect(tag_follow.deliveries.list).to contain_exactly(listed)
      expect(listed.reload.media_only).to be true
      expect(shadow_row(listed.legacy_follow_tag_id).media_only).to be true
      expect_parity_ok
    end

    it 'adds Home to a multi-List relation and keeps each List media_only' do
      stub_follow_tag_mirror
      list_a = Fabricate(:list, account: account, title: 'A')
      list_b = Fabricate(:list, account: account, title: 'B')
      listed_a = writer.create!(account: account, name: 'u3b3elistmany', list: list_a, media_only: true)
      listed_b = writer.create!(account: account, name: 'u3b3elistmany', list: list_b, media_only: false)

      writer.standard_follow!(account: account, tag: listed_a.tag)

      tag_follow = TagFollow.find_by!(account: account, tag: listed_a.tag)
      expect(tag_follow.deliveries.home.count).to eq 1
      expect(tag_follow.deliveries.list.map(&:id)).to contain_exactly(listed_a.id, listed_b.id)
      expect(listed_a.reload.media_only).to be true
      expect(listed_b.reload.media_only).to be false
      expect(FollowTag.where(account: account, tag: listed_a.tag).count).to eq 3
      expect_parity_ok
    end

    it 'does not rewrite Home + List peers on a repeated follow' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'A')
      home = writer.create!(account: account, name: 'u3b3epeers')
      listed = writer.create!(account: account, name: 'u3b3epeers', list: list, media_only: true)

      writer.standard_follow!(account: account, tag: home.tag)

      tag_follow = TagFollow.find_by!(account: account, tag: home.tag)
      expect(tag_follow.deliveries.home).to contain_exactly(home)
      expect(tag_follow.deliveries.list).to contain_exactly(listed)
      expect(listed.reload.media_only).to be true
      expect(FollowTag.where(account: account, tag: home.tag).count).to eq 2
      expect_parity_ok
    end

    it 'records a follows rate-limit event only when creating a new TagFollow' do
      stub_follow_tag_mirror
      tag = Fabricate(:tag, name: 'u3b3erate')
      list = Fabricate(:list, account: account, title: 'A')

      expect { writer.standard_follow!(account: account, tag: tag, rate_limit: true) }
        .to change { follow_rate_limit_count(account) }.by(1)

      listed_tag = Fabricate(:tag, name: 'u3b3eratelist')
      writer.create!(account: account, name: 'u3b3eratelist', list: list)

      expect { writer.standard_follow!(account: account, tag: listed_tag, rate_limit: true) }
        .not_to change { follow_rate_limit_count(account) }
    end

    it 'fails closed on an inconsistent relation and does not add Home' do
      list = Fabricate(:list, account: account, title: 'A')
      tag = Fabricate(:tag, name: 'u3b3ebadfollow')
      tag_follow = TagFollow.create!(account: account, tag: tag)
      listed = TagFollowDelivery.create!(
        tag_follow: tag_follow,
        list: list,
        legacy_follow_tag_id: unused_legacy_id
      )
      before = relation_counts(account, tag)

      expect { writer.standard_follow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)

      expect(relation_counts(account, tag)).to eq before
      expect(tag_follow.deliveries.home).to be_empty
      expect(TagFollowDelivery.where(id: listed.id)).to exist
    end
  end

  describe '#standard_unfollow!' do
    it 'removes a Home-only relation, delivery, and shadow' do
      stub_follow_tag_mirror
      tag = Fabricate(:tag, name: 'u3b3eunhome')
      writer.standard_follow!(account: account, tag: tag)

      writer.standard_unfollow!(account: account, tag: tag)

      expect(TagFollow.where(account: account, tag: tag)).to be_empty
      expect(TagFollowDelivery.for_account(account).for_tags(tag)).to be_empty
      expect(FollowTag.where(account: account, tag: tag)).to be_empty
      expect_parity_ok
    end

    it 'removes a one-List relation and its shadow' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'A')
      listed = writer.create!(account: account, name: 'u3b3eunlist', list: list)

      writer.standard_unfollow!(account: account, tag: listed.tag)

      expect(TagFollow.where(account: account, tag: listed.tag)).to be_empty
      expect(TagFollowDelivery.where(id: listed.id)).to be_empty
      expect(FollowTag.where(account: account, tag: listed.tag)).to be_empty
      expect_parity_ok
    end

    it 'removes every List destination in a multi-List relation' do
      stub_follow_tag_mirror
      list_a = Fabricate(:list, account: account, title: 'A')
      list_b = Fabricate(:list, account: account, title: 'B')
      listed_a = writer.create!(account: account, name: 'u3b3eunlists', list: list_a, media_only: true)
      listed_b = writer.create!(account: account, name: 'u3b3eunlists', list: list_b, media_only: false)

      writer.standard_unfollow!(account: account, tag: listed_a.tag)

      expect(TagFollow.where(account: account, tag: listed_a.tag)).to be_empty
      expect(TagFollowDelivery.where(id: [listed_a.id, listed_b.id])).to be_empty
      expect(FollowTag.where(account: account, tag: listed_a.tag)).to be_empty
      expect_parity_ok
    end

    it 'removes Home and every List together' do
      stub_follow_tag_mirror
      list_a = Fabricate(:list, account: account, title: 'A')
      list_b = Fabricate(:list, account: account, title: 'B')
      home = writer.create!(account: account, name: 'u3b3eunall')
      writer.create!(account: account, name: 'u3b3eunall', list: list_a, media_only: true)
      writer.create!(account: account, name: 'u3b3eunall', list: list_b)

      writer.standard_unfollow!(account: account, tag: home.tag)

      expect(TagFollow.where(account: account, tag: home.tag)).to be_empty
      expect(TagFollowDelivery.for_account(account).for_tags(home.tag)).to be_empty
      expect(FollowTag.where(account: account, tag: home.tag)).to be_empty
      expect_parity_ok
    end

    it 'does not depend on FollowTagMirror for multi-destination unfollow' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'A')
      home = writer.create!(account: account, name: 'u3b3eunmirror')
      writer.create!(account: account, name: 'u3b3eunmirror', list: list)

      writer.standard_unfollow!(account: account, tag: home.tag)

      expect(TagFollow.where(account: account, tag: home.tag)).to be_empty
      expect(FollowTag.where(account: account, tag: home.tag)).to be_empty
      expect_parity_ok
    end

    it 'is a no-op when the relation is already absent' do
      tag = Fabricate(:tag, name: 'u3b3eunabsent')
      before = relation_counts(account, tag)

      writer.standard_unfollow!(account: account, tag: tag)

      expect(relation_counts(account, tag)).to eq before
      expect_parity_ok
    end

    it 'is a no-op for an unsaved Tag' do
      tag = Tag.new(name: 'u3b3eunnew')

      expect { writer.standard_unfollow!(account: account, tag: tag) }.not_to raise_error
      expect(tag).not_to be_persisted
    end

    it 'fails closed when a delivery has no shadow row' do
      tag = Fabricate(:tag, name: 'u3b3emissingshadow')
      home = writer.create!(account: account, name: 'u3b3emissingshadow')
      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).delete_all
      before = relation_counts(account, tag)

      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(relation_counts(account, tag)).to eq before
      expect(TagFollowDelivery.where(id: home.id)).to exist
    end

    it 'fails closed when the shadow account, tag, or list does not match' do
      tag = Fabricate(:tag, name: 'u3b3ewrongfields')
      other_tag = Fabricate(:tag, name: 'u3b3ewrongother')
      list = Fabricate(:list, account: account, title: 'A')
      home = writer.create!(account: account, name: 'u3b3ewrongfields')

      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).update_all(account_id: other.id)
      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(TagFollowDelivery.where(id: home.id)).to exist

      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).update_all(account_id: account.id, tag_id: other_tag.id)
      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(TagFollowDelivery.where(id: home.id)).to exist

      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).update_all(tag_id: tag.id, list_id: list.id)
      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(TagFollowDelivery.where(id: home.id)).to exist
    end

    it 'fails closed when shadow media_only does not match' do
      tag = Fabricate(:tag, name: 'u3b3ewrongmedia')
      home = writer.create!(account: account, name: 'u3b3ewrongmedia')
      FollowTag.unscoped.where(id: home.legacy_follow_tag_id).update_all(media_only: true)
      before = relation_counts(account, tag)

      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(relation_counts(account, tag)).to eq before
    end

    it 'fails closed when an extra legacy-only destination exists' do
      list = Fabricate(:list, account: account, title: 'A')
      home = writer.create!(account: account, name: 'u3b3eextra')
      insert_legacy_follow_tag(account: account, tag: home.tag, list: list)
      before = relation_counts(account, home.tag)

      expect { writer.standard_unfollow!(account: account, tag: home.tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(relation_counts(account, home.tag)).to eq before
      expect(TagFollowDelivery.where(id: home.id)).to exist
    end

    it 'fails closed when TagFollow has zero deliveries' do
      tag = Fabricate(:tag, name: 'u3b3ezerodel')
      tag_follow = TagFollow.create!(account: account, tag: tag)

      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(TagFollow.where(id: tag_follow.id)).to exist
    end

    it 'fails closed when only a legacy shadow exists' do
      tag = Fabricate(:tag, name: 'u3b3elegacyonly')
      shadow = insert_legacy_follow_tag(account: account, tag: tag)

      expect { writer.standard_unfollow!(account: account, tag: tag) }
        .to raise_error(described_class::InconsistentLegacyShadowError)
      expect(FollowTag.where(id: shadow.id)).to exist
      expect(TagFollow.where(account: account, tag: tag)).to be_empty
    end
  end

  describe 'cross-surface interoperability' do
    it 'lets a compatibility-API Home destination participate in standard follow and unfollow' do
      stub_follow_tag_mirror
      home = writer.create!(account: account, name: 'u3b3eapi')

      writer.standard_follow!(account: account, tag: home.tag)
      expect(TagFollow.find_by!(account: account, tag: home.tag).deliveries.home).to contain_exactly(home)
      expect_parity_ok

      writer.standard_unfollow!(account: account, tag: home.tag)
      expect(TagFollow.where(account: account, tag: home.tag)).to be_empty
      expect(FollowTag.where(account: account, tag: home.tag)).to be_empty
      expect_parity_ok
    end

    it 'lets a Settings-writer List destination participate in standard follow and unfollow' do
      stub_follow_tag_mirror
      list = Fabricate(:list, account: account, title: 'A')
      form = Form::FollowTag.new(name: 'u3b3esettings', list_id: list.id, media_only: true)
      listed = writer.create!(account: account, name: form.name, list: list, media_only: form.media_only)

      writer.standard_follow!(account: account, tag: listed.tag)
      tag_follow = TagFollow.find_by!(account: account, tag: listed.tag)
      expect(tag_follow.deliveries.list).to contain_exactly(listed)
      expect(tag_follow.deliveries.home.count).to eq 1
      expect_parity_ok

      writer.standard_unfollow!(account: account, tag: listed.tag)
      expect(TagFollow.where(account: account, tag: listed.tag)).to be_empty
      expect(FollowTag.where(account: account, tag: listed.tag)).to be_empty
      expect_parity_ok
    end
  end
end
