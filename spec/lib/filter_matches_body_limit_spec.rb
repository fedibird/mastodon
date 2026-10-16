# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Mastodon::FilterMatchesBodyLimit do
  let(:app) { ->(env) { [200, {}, [env['rack.input'].read]] } }
  let(:middleware) { described_class.new(app) }

  def env(body, **attributes)
    { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => described_class::PATH, 'rack.input' => StringIO.new(body) }.merge(attributes.transform_keys(&:to_s))
  end

  it 'bounds reads without Content-Length and rejects oversized chunked bodies' do
    input = StringIO.new('x' * 20_000)
    expect(input).to receive(:read).with(8193).once.and_call_original
    expect(middleware.call(env('', 'rack.input' => input)).first).to eq(413)
  end

  it 'rejects an oversized declared body without reading it' do
    input = StringIO.new('')
    expect(input).not_to receive(:read)
    expect(middleware.call(env('', 'rack.input' => input, 'CONTENT_LENGTH' => '8193')).first).to eq(413)
  end

  it 'preserves a permitted body exactly and accepts the boundary' do
    body = 'x' * 8192
    expect(middleware.call(env(body))).to eq([200, {}, [body]])
  end

  it 'leaves other endpoints untouched' do
    expect(middleware.call(env('x' * 8193, 'PATH_INFO' => '/api/v1/statuses')).first).to eq(200)
  end

  it 'handles an empty request stream' do
    expect(middleware.call(env(''))).to eq([200, {}, ['']])
  end

  it 'limits encoded, normalized, and format path variants' do
    paths = ["#{described_class::PATH}.json", "#{described_class::PATH}/", '/api//v1/fedibird/filters/%6datches']
    paths.each do |path|
      expect(middleware.call(env('x' * 8193, 'PATH_INFO' => path)).first).to eq(413)
    end
  end
end
