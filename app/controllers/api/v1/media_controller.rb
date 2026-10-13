# frozen_string_literal: true

class Api::V1::MediaController < Api::BaseController
  before_action -> { doorkeeper_authorize! :write, :'write:media' }
  before_action :require_user!
  before_action :set_media_attachment, except: [:create]
  before_action :check_processing, except: [:create]

  def create
    @media_attachment = PostingIdentity::MediaUpload.create!(
      resolution: media_sender!(:media_create),
      grantee: current_user,
      attributes: media_attachment_params
    )
    render json: @media_attachment, serializer: REST::MediaAttachmentSerializer
  rescue Paperclip::Errors::NotIdentifiedByImageMagickError
    render json: file_type_error, status: 422
  rescue Paperclip::Error
    render json: processing_error, status: 500
  end

  def show
    render json: @media_attachment, serializer: REST::MediaAttachmentSerializer, status: status_code_for_media_attachment
  end

  def update
    @media_attachment.update!(updateable_media_attachment_params)
    render json: @media_attachment, serializer: REST::MediaAttachmentSerializer, status: status_code_for_media_attachment
  end

  private

  def status_code_for_media_attachment
    @media_attachment.not_processed? ? 206 : 200
  end

  def set_media_attachment
    resolution = media_sender!(:media_update)
    scope = resolution.account.media_attachments.where(status_id: nil)
    scope = scope.where(scheduled_status_id: nil) if resolution.delegated?
    @media_attachment = scope.find(params[:id])
    return unless resolution.delegated?

    audit = PostingIdentityMedia.find_by(
      media_attachment_id: @media_attachment.id,
      grantee_user_id: current_user.id,
      delegation_id: resolution.delegation.id,
      posting_account_id: resolution.account.id
    )
    raise ActiveRecord::RecordNotFound if audit.nil?
    raise ActiveRecord::RecordNotFound unless delegated_media_visible?(@media_attachment)
  end

  def check_processing
    render json: processing_error, status: 422 if @media_attachment.processing_failed?
  end

  def media_sender!(purpose)
    PostingIdentity::SendGuard.resolve!(
      user: current_user,
      account_id: params[:account_id],
      posting_identity_id: params[:posting_identity_id],
      purpose: purpose
    )
  end

  # Processing status stays visible so the composer can poll it. A finished
  # file must still be a still image owned through the audit row above.
  def delegated_media_visible?(media)
    media.not_processed? || media.processing_failed? || PostingIdentity::StillImage.acceptable?(media)
  end

  def media_attachment_params
    params.permit(:file, :thumbnail, :description, :focus)
  end

  def updateable_media_attachment_params
    params.permit(:thumbnail, :description, :focus)
  end

  def file_type_error
    { error: 'File type of uploaded media could not be verified' }
  end

  def processing_error
    { error: 'Error processing thumbnail for uploaded media' }
  end
end
