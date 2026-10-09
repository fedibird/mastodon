# frozen_string_literal: true

PostingIdentity::Record = Struct.new(:id, :kind, :provider, :account, :authorization, :capabilities, keyword_init: true) do
  include ActiveModel::Serialization

  def ready?
    authorization == PostingIdentity::AUTHORIZATION_READY
  end

  def self.model_name
    ActiveModel::Name.new(self, nil, 'PostingIdentity')
  end
end
