# frozen_string_literal: true

class PostingIdentity::Local
  extend ActiveModel::Naming
  include ActiveModel::Serialization

  CAPABILITIES = %w(post media reply group schedule).freeze

  attr_reader :account

  def initialize(user)
    @user = user
    @account = user.account
  end

  def id
    "local:#{@account.id}"
  end

  def kind
    'local'
  end

  def provider
    'fedibird'
  end

  # ready is only the signed-in local account while it can actually post.
  # A stored credential, an administrator role, or another user's id is not
  # enough. Suspended, disabled, unapproved, and post-restricted accounts stay
  # out of ready.
  def authorization
    return 'unavailable' unless @user.functional?
    return 'restricted' if @user.setting_disable_post

    'ready'
  end

  def capabilities
    value = authorization == 'ready' ? 'supported' : 'unavailable'

    CAPABILITIES.index_with { value }
  end

  def postable?
    authorization == 'ready' && capabilities['post'] == 'supported' && @account.id == @user.account_id
  end
end
