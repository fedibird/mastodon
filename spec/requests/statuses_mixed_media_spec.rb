# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public pages for mixed media' do
  before do
    allow(Webpacker.instance.manifest).to receive(:lookup).and_return('/packs-test/stub')
    allow(Webpacker.instance.manifest).to receive(:lookup!) do |_name, with_integrity: false, **|
      with_integrity ? ['/packs-test/stub', nil] : '/packs-test/stub'
    end
  end

  def store_media(status, type, name)
    MediaAttachment.new(
      account: status.account,
      status: status,
      type: type,
      remote_url: "https://cdn.example/#{name}",
      description: name,
      file_file_name: "#{name}.bin",
      file_content_type: type == :audio ? 'audio/mpeg' : 'video/mp4',
      file_file_size: 10
    ).tap { |media| media.save!(validate: false) }
  end

  def attach_in_order(status, pairs)
    media = pairs.map { |type, name| store_media(status, type, name) }
    status.update!(ordered_media_attachment_ids: media.map(&:id))
    status.media_attachments.reset
    media
  end

  def stack_props(body)
    Nokogiri::HTML(body).css('[data-component="StatusMediaStack"]').map { |node| JSON.parse(node['data-props']) }
  end

  def names_of(props)
    props.fetch('media').map { |item| item.fetch('description') }
  end

  it 'renders simple, detailed, and quote stacks with every attachment in order' do
    alice = Fabricate(:account, username: 'alice')
    bob = Fabricate(:account, username: 'bob')
    ancestor = Fabricate(:status, account: alice, text: 'ancestor note', visibility: :public)
    quoted = Fabricate(:status, account: bob, text: 'quoted note', visibility: :public)
    status = Fabricate(:status, account: alice, text: 'detail note', visibility: :public, thread: ancestor, quote: quoted)
    attach_in_order(ancestor, [%i(audio talk-a), %i(audio talk-b)])
    attach_in_order(quoted, [%i(image photo-a), %i(video clip-a), %i(image photo-b), %i(video clip-b), %i(audio talk-c)])
    attach_in_order(status, [%i(gifv loop), %i(video clip-c), %i(image photo-c), %i(unknown missing)])

    get "/@alice/#{status.id}"

    expect(response).to have_http_status(200)
    stacks = stack_props(response.body)
    expect(stacks.map { |props| names_of(props) }).to eq([
      %w(talk-a talk-b),
      %w(photo-a clip-a photo-b clip-b talk-c),
      %w(loop clip-c photo-c missing),
    ])
    expect(stacks[0]).to include('height' => 343, 'defaultWidth' => 610, 'quote' => false)
    expect(stacks[0]).not_to have_key('detailed')
    expect(stacks[1]).to include('quote' => true, 'audioHeight' => 60, 'height' => 343, 'defaultWidth' => 610)
    expect(stacks[2]).to include('detailed' => true, 'standalone' => true, 'height' => 380, 'defaultWidth' => 670, 'quote' => false)
    expect(stacks[2].fetch('media').map { |item| item.fetch('type') }).to eq(%w(gifv video image unknown))

    %w(talk-a talk-b photo-a clip-a photo-b clip-b talk-c loop clip-c photo-c missing).each do |name|
      expect(response.body).to include("https://cdn.example/#{name}")
    end
    expect(response.body).to include('attachment-list')

    header = Nokogiri::HTML.fragment(response.body)
    expect(header.css('meta[property="og:video"]').size).to eq(1)
    expect(header.css('meta[property="twitter:player"]').size).to eq(1)
    expect(header.css('meta[property="twitter:card"]').first['content']).to eq('player')

    get "/@alice/#{status.id}/embed"
    expect(response).to have_http_status(200)
    embed_stacks = stack_props(response.body)
    expect(embed_stacks.map { |props| names_of(props) }).to eq([
      %w(photo-a clip-a photo-b clip-b talk-c),
      %w(loop clip-c photo-c missing),
    ])
  end

  it 'picks the leading image as the only Open Graph card when an image comes first' do
    alice = Fabricate(:account, username: 'carol')
    status = Fabricate(:status, account: alice, text: 'image then videos', visibility: :public)
    attach_in_order(status, [%i(image photo), %i(video clip-a), %i(video clip-b)])

    get "/@carol/#{status.id}"

    header = Nokogiri::HTML(response.body)
    expect(header.css('meta[property="og:video"]')).to be_empty
    expect(header.css('meta[property="twitter:player"]')).to be_empty
    expect(header.css('meta[property="og:image"]').size).to eq(1)
    expect(header.css('meta[property="twitter:card"]').first['content']).to eq('summary_large_image')
    expect(stack_props(response.body).first.fetch('media').map { |item| item.fetch('description') }).to eq(%w(photo clip-a clip-b))
  end
end
