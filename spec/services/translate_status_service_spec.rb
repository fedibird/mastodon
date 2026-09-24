# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TranslateStatusService do
  let(:account) { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: account, text: 'Hello :blob: <script>alert(1)</script>', spoiler_text: 'Secret', language: 'en', visibility: :public) }
  let(:backend) { instance_double(TranslationService::DeepL) }

  before do
    Fabricate(:custom_emoji, shortcode: 'blob', domain: nil)
    allow(TranslationService).to receive(:configured?).and_return(true)
    allow(TranslationService).to receive(:configured).and_return(backend)
    allow(backend).to receive(:languages).and_return('en' => ['ja'], nil => ['ja'])
    allow(backend).to receive(:translate) do |texts, _source, _target|
      texts.map do |text|
        TranslationService::Translation.new(text: "JA #{text}", detected_source_language: 'en', provider: 'DeepL.com')
      end
    end
    Rails.cache.clear
  end

  it 'translates content, spoiler, poll options, and media descriptions' do
    poll = Fabricate(:poll, status: status, options: ['Yes', 'No'])
    status.update!(poll_id: poll.id)
    media = Fabricate(:media_attachment, status: status, account: account, description: 'A cat &amp; dog')

    translation = described_class.new.call(status.reload, 'ja')

    expect(translation.content).to include('JA')
    expect(translation.content).to include(':blob:')
    expect(translation.content).not_to include('<script>')
    expect(translation.spoiler_text).to include('Secret')
    expect(translation.poll_options.map(&:title)).to include(a_string_including('Yes'), a_string_including('No'))
    expect(translation.media_attachments.map(&:id)).to eq [media.id]
    expect(translation.provider).to eq 'DeepL.com'
    expect(translation.detected_source_language).to eq 'en'
  end

  it 'preserves emoji shortcodes sent to the provider' do
    described_class.new.call(status, 'ja')

    expect(backend).to have_received(:translate).with(array_including(a_string_including('<span translate="no">:blob:</span>')), 'en', 'ja')
  end

  it 'refuses a non-distributable status' do
    status.update!(visibility: :direct)

    expect { described_class.new.call(status, 'ja') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'refuses an unsupported language pair' do
    expect { described_class.new.call(status, 'de') }.to raise_error(Mastodon::NotPermittedError)
    expect(backend).not_to have_received(:translate)
  end

  it 'refuses translation when no provider is configured' do
    allow(TranslationService).to receive(:configured?).and_return(false)

    expect { described_class.new.call(status, 'ja') }.to raise_error(Mastodon::NotPermittedError)
  end

  it 'reuses the cache until the status content changes' do
    described_class.new.call(status, 'ja')
    described_class.new.call(status, 'ja')
    status.update!(text: 'Edited hello')
    described_class.new.call(status, 'ja')

    expect(backend).to have_received(:translate).twice
  end
end
