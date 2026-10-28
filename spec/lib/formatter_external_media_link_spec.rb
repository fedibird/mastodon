# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Formatter do
  let(:owner) { Fabricate(:user) }

  def attach_images(status, count)
    now = Time.current
    count.times do
      MediaAttachment.insert(
        {
          account_id: status.account_id,
          status_id: status.id,
          remote_url: '',
          file_file_name: 'pixel.jpg',
          file_content_type: 'image/jpeg',
          file_file_size: 8,
          type: 0,
          created_at: now,
          updated_at: now,
        }
      )
    end
    status.media_attachments.reset
  end

  def html_for(status)
    Formatter.instance.format(status.reload)
  end

  describe 'original media compatibility link' do
    it 'omits the link at four attachments and keeps it at five for an ordinary status' do
      ordinary = Fabricate(:status, account: owner.account, text: 'Hello', visibility: :public)
      attach_images(ordinary, 4)

      expect(html_for(ordinary)).not_to include('original-media-link')

      attach_images(ordinary, 1)
      html = html_for(ordinary)
      link = Nokogiri::HTML.fragment(html).at_css('.original-media-link a')

      expect(link).to be_present
      expect(link['href']).to be_present
      expect(link['href']).not_to eq('')
      expect(html).to include('Attached: 5 images')
    end

    it 'does not build a link when the public URL is blank' do
      ordinary = Fabricate(:status, account: owner.account, text: 'Hello', visibility: :public)
      attach_images(ordinary, 5)
      allow(ActivityPub::TagManager.instance).to receive(:url_for).and_return(nil)

      expect(html_for(ordinary)).not_to include('original-media-link')
      expect(Formatter.instance.add_original_link_from_status('<p>Hello</p>', ordinary.reload)).to eq('<p>Hello</p>')

      allow(ActivityPub::TagManager.instance).to receive(:url_for).and_return('')
      expect(html_for(ordinary)).not_to include('href=""')
      expect(html_for(ordinary)).not_to include('original-media-link')
    end

    it 'suppresses the link for a private projection even when a URL is offered' do
      bundle = external_project_for(owner, body: 'Imported article')
      status = bundle[:status]
      attach_images(status, 5)
      allow(ActivityPub::TagManager.instance).to receive(:url_for).and_return('https://example.com/should-not-appear')

      expect(ExternalBridge::ProjectionPrivacy.private_status?(status.reload)).to be true

      ['Imported article', ''].each do |text|
        status.update_columns(text: text)
        html = html_for(status)
        expect(html).not_to include('original-media-link')
        expect(html).not_to include('should-not-appear')
        expect(html).not_to include('href=""')
        expect(html).not_to include(bundle[:resource].canonical_url)
        direct = Formatter.instance.add_original_link_from_status(text.present? ? '<p>Imported article</p>' : '', status.reload)
        expect(direct).not_to include('original-media-link')
        expect(direct).not_to include('should-not-appear')
      end
    end

    it 'suppresses a public in-memory row that is flagged as a projection' do
      status = Status.new(account: owner.account, text: 'Hello', visibility: :public, external_projection: true, local: true)

      expect(status.id).to be_nil
      expect(ExternalBridge::ProjectionPrivacy.private_status?(status)).to be true
      expect(Formatter.instance.add_original_link_from_status('<p>Hello</p>', status)).to eq('<p>Hello</p>')
    end

    it 'suppresses the link when the marker is gone and the projection flag remains' do
      bundle = external_project_for(owner, body: 'Imported article')
      status = bundle[:status]
      attach_images(status, 5)
      ApplicationRecord.transaction(requires_new: true) do
        ActiveRecord::Base.connection.execute(ExternalBridge::ProjectionPurge::SETTING_SQL)
        ExternalStatusProjection.where(id: bundle[:marker].id).delete_all
        ActiveRecord::Base.connection.execute("SET LOCAL fedibird.projection_status_delete = 'off'")
      end
      damaged = Status.find(status.id)

      expect(damaged.external_projection).to be true
      expect(ExternalStatusProjection.where(status_id: damaged.id)).to be_empty
      expect(ExternalBridge::ProjectionPrivacy.private_status?(damaged)).to be true
      expect(html_for(damaged)).not_to include('original-media-link')
      expect(Formatter.instance.add_original_link_from_status('<p>Imported article</p>', damaged)).not_to include('original-media-link')
    end

    it 'keeps the remote compatibility helper that already has a URL' do
      html = Formatter.instance.add_original_link('<p>Remote</p>', 'https://example.com/remote/1', 'Attached: 5 images')

      expect(html).to include('class="unhandled-link"')
      expect(html).to include('https://example.com/remote/1')
    end
  end
end
