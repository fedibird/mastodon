# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ResolveRedirectLinkService, type: :service do
  subject { described_class.new }

  def stub_get(url, code:, final_url:)
    response = instance_double(HTTP::Response, code: code, uri: final_url)
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_yield(response)
    allow(Request).to receive(:new).with(:get, url).and_return(request)
  end

  it 'returns an existing mapping without HTTP' do
    url = 'https://bit.ly/cached'
    link = RedirectLink.create!(url: url, redirected_url: 'https://example.com/cached')
    expect(Request).not_to receive(:new)

    expect(subject.call(url)).to eq link
  end

  it 'ignores a URL that is not a redirect host' do
    expect(Request).not_to receive(:new)

    expect(subject.call('https://example.com/article')).to be_nil
    expect(RedirectLink.count).to eq 0
  end

  it 'stores a confirmed redirect target' do
    short_url = 'https://bit.ly/abc'
    final_url = 'https://example.com/landed'
    stub_get(short_url, code: 200, final_url: final_url)
    stub_get(final_url, code: 200, final_url: final_url)

    link = subject.call(short_url)

    expect(link.url).to eq short_url
    expect(link.redirected_url).to eq final_url
  end

  it 'stores an identity mapping when the final URL is unchanged' do
    url = 'https://bit.ly/same'
    stub_get(url, code: 200, final_url: url)

    link = subject.call(url)

    expect(link.url).to eq url
    expect(link.redirected_url).to eq url
    expect(Request).to have_received(:new).with(:get, url).once
  end

  it 'stores the original URL when the only change is a language path' do
    url = 'https://bit.ly/campaign'
    language_url = 'https://bit.ly/en'
    stub_get(url, code: 200, final_url: language_url)

    link = subject.call(url)

    expect(link.url).to eq url
    expect(link.redirected_url).to eq url
    expect(Request).not_to have_received(:new).with(:get, language_url)
  end

  it 'raises a temporary failure on timeout and stores nothing' do
    url = 'https://bit.ly/slow'
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_raise(HTTP::TimeoutError, 'execution expired')
    allow(Request).to receive(:new).with(:get, url).and_return(request)

    expect { subject.call(url) }.to raise_error(described_class::TemporaryFailure) { |error|
      expect(error.url).to eq url
    }
    expect(RedirectLink.find_by(url: url)).to be_nil
  end

  it 'raises a permanent failure for an unusable status and stores nothing' do
    url = 'https://bit.ly/missing'
    stub_get(url, code: 404, final_url: url)

    expect { subject.call(url) }.to raise_error(described_class::PermanentFailure) { |error|
      expect(error.url).to eq url
    }
    expect(RedirectLink.find_by(url: url)).to be_nil
  end

  it 'does not store a redirect when confirming the target fails temporarily' do
    short_url = 'https://bit.ly/flaky'
    final_url = 'https://example.com/flaky'
    stub_get(short_url, code: 200, final_url: final_url)
    request = instance_double(Request)
    allow(request).to receive(:add_headers).and_return(request)
    allow(request).to receive(:perform).and_raise(HTTP::TimeoutError, 'execution expired')
    allow(Request).to receive(:new).with(:get, final_url).and_return(request)

    expect { subject.call(short_url) }.to raise_error(described_class::TemporaryFailure) { |error|
      expect(error.url).to eq short_url
    }
    expect(RedirectLink.find_by(url: short_url)).to be_nil
  end
end
