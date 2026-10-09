# frozen_string_literal: true

class REST::PostingIdentitySerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :id, :kind, :provider, :authorization, :capabilities, :account

  def account
    record = object.account

    {
      id: record.id.to_s,
      acct: record.pretty_acct,
      display_name: record.display_name,
      avatar: avatar_url(record, static: false),
      avatar_static: avatar_url(record, static: true),
    }
  end

  private

  def avatar_url(record, static:)
    path = if record.suspended?
             record.avatar.default_url
           elsif static
             record.avatar_static_url
           else
             record.avatar_original_url
           end

    full_asset_url(path)
  end
end
