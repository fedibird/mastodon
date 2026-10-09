# frozen_string_literal: true

class REST::PostingIdentitySerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :id, :kind, :provider, :authorization, :capabilities, :account

  def account
    account = object.account

    {
      id: account.id.to_s,
      acct: account.pretty_acct,
      display_name: account.display_name,
      avatar: full_asset_url(account.suspended? ? account.avatar.default_url : account.avatar_original_url),
      avatar_static: full_asset_url(account.suspended? ? account.avatar.default_url : account.avatar_static_url, ext: account.avatar_file_name),
    }
  end
end
