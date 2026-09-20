# frozen_string_literal: true

module HashtagUnification
  # Canonical create/update/destroy for TagFollowDelivery, plus relation-level
  # standard follow/unfollow. Compatibility IDs are allocated from the existing
  # follow_tags sequence via a callback-free rollback shadow.
  #
  # Lock order for update/destroy and relation-level work:
  # follow_tags rows first, then TagFollowDelivery rows, then parent TagFollow.
  class TagFollowDeliveryWriter
    UNCHANGED = Object.new.freeze

    class InconsistentLegacyShadowError < Mastodon::ValidationError
      def initialize(message = 'Follow tag rollback shadow is inconsistent')
        super
      end
    end

    def create!(account:, name:, list: nil, media_only: false)
      tag = resolve_tag!(name)

      ApplicationRecord.transaction do
        tag_follow = find_or_create_tag_follow(account, tag)
        delivery = tag_follow.deliveries.new(list: list)
        delivery.media_only = media_only
        delivery.save!
        assign_shadow_id!(delivery)
        delivery
      end
    end

    def update!(account:, legacy_resource_id:, name: UNCHANGED, list: UNCHANGED, media_only: UNCHANGED)
      ApplicationRecord.transaction do
        shadow = lock_shadow!(account, legacy_resource_id)
        delivery = lock_canonical_delivery!(account, legacy_resource_id)
        verify_shadow_matches!(shadow, delivery)

        old_follow = delivery.tag_follow
        apply_name!(delivery, name) unless unchanged?(name)
        apply_list!(delivery, list) unless unchanged?(list)
        apply_media_only!(delivery, media_only) unless unchanged?(media_only)

        delivery.save!
        sync_shadow!(delivery)
        cleanup_empty_tag_follow!(old_follow)
        delivery
      end
    end

    def destroy!(account:, legacy_resource_id:)
      ApplicationRecord.transaction do
        shadow = lock_shadow!(account, legacy_resource_id)
        delivery = lock_canonical_delivery!(account, legacy_resource_id)
        verify_shadow_matches!(shadow, delivery)

        tag_follow = delivery.tag_follow
        compatibility_id = delivery.legacy_follow_tag_id
        delivery.destroy!
        delete_shadow!(compatibility_id)
        cleanup_empty_tag_follow!(tag_follow)
      end
    end

    def standard_follow!(account:, tag:, rate_limit: false)
      ApplicationRecord.transaction do
        persisted_tag = persist_tag!(tag)
        verify_or_allow_empty_relation!(account, persisted_tag)
        tag_follow = find_or_create_tag_follow_with_rate_limit(account, persisted_tag, rate_limit)
        ensure_home_delivery!(tag_follow)
        persisted_tag.reload
      end
    end

    def standard_unfollow!(account:, tag:)
      return if tag.new_record?

      ApplicationRecord.transaction do
        tag_follow = verify_or_allow_empty_relation!(account, tag)
        if tag_follow
          tag_follow.deliveries.delete_all
          FollowTag.unscoped.where(account: account, tag: tag).delete_all
          tag_follow.destroy!
        end
      end
    end

    private

    def unchanged?(value)
      value.equal?(UNCHANGED)
    end

    def resolve_tag!(name)
      raise ActiveRecord::RecordInvalid, Tag.new if name.blank?

      tag = Tag.find_or_create_by_names(name.to_s.strip)&.first
      raise ActiveRecord::RecordInvalid, (tag || Tag.new) unless tag&.persisted?

      tag
    end

    def find_or_create_tag_follow(account, tag)
      TagFollow.find_or_create_by!(account: account, tag: tag)
    rescue ActiveRecord::RecordNotUnique
      TagFollow.find_by!(account: account, tag: tag)
    end

    def persist_tag!(tag)
      return tag if tag.persisted?

      tag.save!
      tag
    end

    def find_or_create_tag_follow_with_rate_limit(account, tag, rate_limit)
      existing = TagFollow.find_by(account: account, tag: tag)
      return existing if existing

      TagFollow.create_with(rate_limit: rate_limit).find_or_create_by!(account: account, tag: tag)
    rescue ActiveRecord::RecordNotUnique
      TagFollow.find_by!(account: account, tag: tag)
    end

    def ensure_home_delivery!(tag_follow)
      home = tag_follow.deliveries.home.lock.first
      return home if home

      delivery = tag_follow.deliveries.new
      delivery.media_only = false
      delivery.save!
      assign_shadow_id!(delivery)
      delivery
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      existing = tag_follow.deliveries.reload.home.first
      raise unless existing

      existing
    end

    def verify_or_allow_empty_relation!(account, tag)
      shadows = lock_relation_shadows(account, tag)
      tag_follow = TagFollow.find_by(account: account, tag: tag)
      return if tag_follow.nil? && shadows.empty?

      raise InconsistentLegacyShadowError if tag_follow.nil?

      deliveries = tag_follow.deliveries.lock.to_a
      raise InconsistentLegacyShadowError if deliveries.empty?

      tag_follow.lock!
      verify_relation_correspondence!(account, tag, deliveries, shadows)
      tag_follow
    end

    def lock_relation_shadows(account, tag)
      connection.select_all(<<~SQL.squish).to_a
        SELECT id, account_id, tag_id, list_id, media_only
        FROM follow_tags
        WHERE account_id = #{connection.quote(account.id)}
          AND tag_id = #{connection.quote(tag.id)}
        FOR UPDATE
      SQL
    end

    def verify_relation_correspondence!(account, tag, deliveries, shadows)
      raise InconsistentLegacyShadowError if deliveries.any? { |delivery| delivery.legacy_follow_tag_id.nil? }
      raise InconsistentLegacyShadowError unless deliveries.size == shadows.size

      shadows_by_id = shadows.index_by { |row| row['id'].to_i }
      raise InconsistentLegacyShadowError unless shadows_by_id.size == shadows.size

      deliveries.each do |delivery|
        row = shadows_by_id[delivery.legacy_follow_tag_id]
        raise InconsistentLegacyShadowError if row.nil?
        raise InconsistentLegacyShadowError unless row['account_id'].to_i == account.id
        raise InconsistentLegacyShadowError unless row['tag_id'].to_i == tag.id
        raise InconsistentLegacyShadowError unless row['list_id']&.to_i == delivery.list_id
        raise InconsistentLegacyShadowError unless boolean_cast(row['media_only']) == delivery.media_only
      end
    end

    def boolean_cast(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def assign_shadow_id!(delivery)
      shadow_id = insert_shadow_row(delivery)
      delivery.update!(legacy_follow_tag_id: shadow_id)
      sync_shadow!(delivery)
    end

    def insert_shadow_row(delivery)
      connection.select_value(<<~SQL.squish).to_i
        INSERT INTO follow_tags (account_id, tag_id, list_id, media_only, created_at, updated_at)
        VALUES (
          #{connection.quote(delivery.account_id)},
          #{connection.quote(delivery.tag_id)},
          #{connection.quote(delivery.list_id)},
          #{quoted_boolean(delivery.media_only)},
          #{connection.quote(delivery.created_at)},
          #{connection.quote(delivery.updated_at)}
        )
        RETURNING id
      SQL
    end

    def lock_shadow!(account, legacy_resource_id)
      row = connection.select_one(<<~SQL.squish)
        SELECT id, account_id, tag_id, list_id
        FROM follow_tags
        WHERE id = #{connection.quote(legacy_resource_id)}
        FOR UPDATE
      SQL

      if row.nil?
        raise InconsistentLegacyShadowError if canonical_delivery_for(account, legacy_resource_id)
        raise ActiveRecord::RecordNotFound
      end

      raise ActiveRecord::RecordNotFound unless row['account_id'].to_i == account.id

      row
    end

    def lock_canonical_delivery!(account, legacy_resource_id)
      delivery = canonical_delivery_for(account, legacy_resource_id)
      raise InconsistentLegacyShadowError if delivery.nil?

      delivery.lock!
    end

    def canonical_delivery_for(account, legacy_resource_id)
      TagFollowDelivery.for_account(account).find_by(legacy_follow_tag_id: legacy_resource_id)
    end

    def verify_shadow_matches!(shadow, delivery)
      same_account = shadow['account_id'].to_i == delivery.account_id
      same_tag = shadow['tag_id'].to_i == delivery.tag_id
      same_list = shadow['list_id']&.to_i == delivery.list_id
      return if same_account && same_tag && same_list

      raise InconsistentLegacyShadowError
    end

    def apply_name!(delivery, name)
      tag = resolve_tag!(name)
      return if tag.id == delivery.tag_id

      delivery.tag_follow = find_or_create_tag_follow(delivery.account, tag)
    end

    def apply_list!(delivery, list)
      delivery.list = list
    end

    def apply_media_only!(delivery, media_only)
      delivery.media_only = media_only
    end

    def sync_shadow!(delivery)
      FollowTag.unscoped.where(id: delivery.legacy_follow_tag_id).update_all(
        account_id: delivery.account_id,
        tag_id: delivery.tag_id,
        list_id: delivery.list_id,
        media_only: delivery.media_only,
        updated_at: delivery.updated_at
      )
    end

    def delete_shadow!(legacy_resource_id)
      FollowTag.unscoped.where(id: legacy_resource_id).delete_all
    end

    def cleanup_empty_tag_follow!(tag_follow)
      tag_follow.lock!
      return if tag_follow.deliveries.exists?

      tag_follow.destroy!
    end

    def quoted_boolean(value)
      value ? 'TRUE' : 'FALSE'
    end

    def connection
      ApplicationRecord.connection
    end
  end
end
