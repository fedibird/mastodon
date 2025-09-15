# frozen_string_literal: true

class REST::NotificationSerializer < ActiveModel::Serializer
  attributes :id, :type, :created_at

  attribute :filtered, if: :filtered?

  belongs_to :from_account, key: :account, serializer: REST::AccountSerializer
  belongs_to :target_account, if: :follow_type?, serializer: REST::AccountSerializer
  attribute :target_status, key: :status, if: :status_type?
  belongs_to :emoji_reaction, if: :emoji_reaction?
  attribute :reblog_visibility, if: :reblog?

  def id
    object.id.to_s
  end

  def status_type?
    [:favourite, :reblog, :status, :mention, :poll, :emoji_reaction, :status_reference, :scheduled_status].include?(object.type) && object.target_status.present?
  end

  def follow_type?
    [:follow, :follow_request, :followed].include?(object.type)
  end

  def reblog?
    object.type == :reblog
  end

  def emoji_reaction?
    object.type == :emoji_reaction
  end

  def filtered?
    false
  end
  # delegate :filtered?, to: :object

  def target_status
      REST::StatusSerializer.new(object.target_status, root: false, relationships: instance_options[:relationships], account_relationships: instance_options[:account_relationships], application_name: instance_options[:application_name], compact: false, scope: current_user, scope_name: :current_user)
  end

  class EmojiReactionSerializer < REST::GroupedEmojiReactionSerializer
    attributes :me

    def me
       false
    end
  end
end
