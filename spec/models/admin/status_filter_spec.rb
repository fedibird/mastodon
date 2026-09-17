# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::StatusFilter do
  let(:account) { Fabricate(:account) }

  describe '::KEYS' do
    it 'exposes media and report_id' do
      expect(described_class::KEYS).to eq %i(media report_id)
    end
  end

  describe '#results' do
    let!(:public_status) { Fabricate(:status, account: account, visibility: :public) }
    let!(:expired_status) { Fabricate(:status, account: account, visibility: :public, expired_at: 1.hour.ago) }
    let!(:private_status) { Fabricate(:status, account: account, visibility: :private) }
    let!(:media_status) { Fabricate(:status, account: account, visibility: :public) }
    let!(:media_attachment) do
      MediaAttachment.new(
        account: account,
        status: media_status,
        type: :image,
        file_file_name: 'test.jpg',
        file_content_type: 'image/jpeg',
        file_file_size: 1
      ).tap { |media| media.save!(validate: false) }
    end

    it 'includes expired public posts and excludes private posts' do
      ids = described_class.new(account, {}).results.pluck(:id)

      expect(ids).to include(public_status.id, expired_status.id, media_status.id)
      expect(ids).not_to include(private_status.id)
    end

    it 'limits results to media attachments when media is set' do
      ids = described_class.new(account, media: true).results.pluck(:id)

      expect(ids).to contain_exactly(media_status.id)
    end

    it 'keeps expired public media and excludes private and other-account media' do
      expired_media_status = Fabricate(:status, account: account, visibility: :public, expired_at: 1.hour.ago)
      private_media_status = Fabricate(:status, account: account, visibility: :private)
      other_account = Fabricate(:account)
      other_media_status = Fabricate(:status, account: other_account, visibility: :public)

      attach_media(account, expired_media_status)
      attach_media(account, private_media_status)
      attach_media(other_account, other_media_status)

      ids = described_class.new(account, media: true).results.pluck(:id)

      expect(ids).to include(expired_media_status.id, media_status.id)
      expect(ids).not_to include(private_media_status.id, other_media_status.id, private_status.id)
    end

    it 'ignores report_id without changing the scope' do
      ids = described_class.new(account, report_id: '12').results.pluck(:id)

      expect(ids).to include(public_status.id, expired_status.id, media_status.id)
    end
  end

  def attach_media(account, status)
    MediaAttachment.new(
      account: account,
      status: status,
      type: :image,
      file_file_name: 'test.jpg',
      file_content_type: 'image/jpeg',
      file_file_size: 1
    ).tap { |media| media.save!(validate: false) }
  end
end
