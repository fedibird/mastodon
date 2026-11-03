# frozen_string_literal: true

# Timeline filtering tests only need a media_attachment row. A remote media
# record without an uploaded file avoids invoking ImageMagick/Paperclip for an
# unrelated thumbnail conversion, and exercises the same SQL EXISTS condition.
module MediaOnlyAttachmentHelper
  def attach_remote_test_image(status)
    status.media_attachments.create!(
      account: status.account,
      remote_url: "https://media.example.invalid/#{status.id}/#{SecureRandom.hex(4)}.jpg",
      type: :image
    )
  end
end

RSpec.configure do |config|
  config.include MediaOnlyAttachmentHelper
end
