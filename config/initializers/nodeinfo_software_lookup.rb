# frozen_string_literal: true

# One NodeInfo software lookup per serialized collection, from rows already
# stored by UpdateNodeService. Reloading in development must not stack preloads.
Rails.application.reloader.to_prepare do
  serializer = ActiveModel::Serializer::CollectionSerializer
  next if serializer < NodeInfoSoftwareLookup::CollectionPreload

  serializer.prepend(NodeInfoSoftwareLookup::CollectionPreload)
end
