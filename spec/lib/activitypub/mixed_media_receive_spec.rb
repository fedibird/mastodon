# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'ActivityPub mixed media receive' do
  let(:sender) do
    Fabricate(
      :account,
      username: 'alice',
      domain: 'example.com',
      uri: 'https://example.com/users/alice',
      inbox_url: 'https://example.com/users/alice/inbox',
      followers_url: 'https://example.com/users/alice/followers'
    )
  end

  before do
    stub_request(:get, %r{https://cdn\.example/}).to_return(status: 200, body: '', headers: { 'Content-Type' => 'application/octet-stream' })
    allow_any_instance_of(MediaAttachment).to receive(:download_file!) do |media|
      kind = media.remote_url.to_s[/kind-([a-z]+)/, 1]
      next if kind.blank? || kind == 'unknown'

      media.type = kind
      media.file_content_type = {
        'image' => 'image/png',
        'gifv' => 'image/gif',
        'video' => 'video/mp4',
        'audio' => 'audio/mpeg',
      }.fetch(kind)
    end
    allow_any_instance_of(MediaAttachment).to receive(:download_thumbnail!)
    allow(RedownloadMediaWorker).to receive(:perform_in)
  end

  def document(kind, index)
    media_type = {
      'image' => 'image/png',
      'gifv' => 'image/gif',
      'video' => 'video/mp4',
      'audio' => 'audio/mpeg',
      'unknown' => 'application/pdf',
    }.fetch(kind)

    {
      type: 'Document',
      mediaType: media_type,
      url: "https://cdn.example/kind-#{kind}-#{index}",
      name: "#{kind}-#{index}",
    }
  end

  def with_attachment_cap(value)
    previous = Setting.attachments_max
    Setting.attachments_max = value
    yield
  ensure
    Setting.attachments_max = previous
  end

  def deliver_create(attachments, cap: 8)
    object_id = "https://example.com/users/alice/statuses/#{SecureRandom.hex(4)}"
    json = {
      '@context': 'https://www.w3.org/ns/activitystreams',
      id: "#{object_id}/activity",
      type: 'Create',
      actor: ActivityPub::TagManager.instance.uri_for(sender),
      object: {
        id: object_id,
        type: 'Note',
        content: 'Mixed remote post',
        attachment: attachments,
      },
    }.with_indifferent_access

    status = nil
    with_attachment_cap(cap) do
      ActivityPub::Activity::Create.new(json, sender).perform
      status = sender.statuses.find_by!(uri: object_id)
    end
    status
  end

  def deliver_update(status, attachments, cap: 8)
    payload = {
      id: status.uri,
      type: 'Note',
      content: 'Mixed remote post',
      updated: '2026-10-28T00:00:00Z',
      attachment: attachments,
    }
    json = Oj.load(Oj.dump(payload))

    with_attachment_cap(cap) do
      ActivityPub::ProcessStatusUpdateService.new.call(status, json, json)
    end
    status.reload
  end

  def remote_urls(status)
    status.ordered_media_attachments.map(&:remote_url)
  end

  {
    'image video image video audio' => %w(image video image video audio),
    'two videos' => %w(video video),
    'gifv video image' => %w(gifv video image),
    'two audios' => %w(audio audio),
    'two images' => %w(image image),
    'unknown then video' => %w(unknown video),
    'no attachments' => [],
  }.each do |label, kinds|
    it "keeps #{label} in order on create and update" do
      attachments = kinds.each_with_index.map { |kind, index| document(kind, index) }
      status = deliver_create(attachments)
      expect(remote_urls(status)).to eq(attachments.map { |row| row[:url] })
      expect(status.ordered_media_attachments.map { |media| media.type.to_s }).to eq(kinds)

      reversed = attachments.reverse
      deliver_update(status, reversed)
      expect(remote_urls(status)).to eq(reversed.map { |row| row[:url] })
      expect(status.ordered_media_attachments.map { |media| media.type.to_s }).to eq(kinds.reverse)
    end
  end

  it 'stops at the attachment cap without discarding an earlier video for a later image' do
    attachments = %w(image video image video audio).each_with_index.map { |kind, index| document(kind, index) }
    status = deliver_create(attachments, cap: 4)

    expect(remote_urls(status)).to eq(attachments.first(4).map { |row| row[:url] })
    expect(status.ordered_media_attachments.map(&:type)).to eq(%w(image video image video))
  end

  it 'does not apply the local single audio-or-video rule while receiving' do
    attachments = [document('video', 1), document('image', 2), document('video', 3)]
    status = deliver_create(attachments)

    expect(status.ordered_media_attachments.map(&:type)).to eq(%w(video image video))
    expect(status).to be_persisted
  end
end
