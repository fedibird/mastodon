# frozen_string_literal: true

# == Schema Information
#
# Table name: external_media_asset_resources
#
#  id                       :bigint(8)        not null, primary key
#  external_media_asset_id  :bigint(8)        not null
#  external_resource_id     :bigint(8)        not null
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#
# Which catalog row still publishes a shared asset's digest. The URL stays
# on that resource's candidate list. This row is how a later revalidation
# finds the URL again without scanning every resource.
class ExternalMediaAssetResource < ApplicationRecord
  belongs_to :external_media_asset
  belongs_to :external_resource
end
