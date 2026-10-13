# frozen_string_literal: true

class Api::V2::MediaController < Api::V1::MediaController
  def create
    @media_attachment = PostingIdentity::MediaUpload.create!(
      resolution: media_sender!(:media_create),
      grantee: current_user,
      attributes: { delay_processing: true }.merge(media_attachment_params)
    )
    render json: @media_attachment,
           serializer: REST::MediaAttachmentSerializer,
           status: @media_attachment.not_processed? ? 202 : 200
  rescue Paperclip::Errors::NotIdentifiedByImageMagickError
    render json: file_type_error, status: 422
  rescue Paperclip::Error
    render json: processing_error, status: 500
  end
end
