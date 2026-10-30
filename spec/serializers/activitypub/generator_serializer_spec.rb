# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivityPub::GeneratorSerializer do
  include RoutingHelper

  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        application,
        serializer: described_class,
        adapter: ActivityPub::Adapter
      ).to_json
    )
  end

  # Build without saving so legacy or otherwise invalid websites reach the serializer.
  let(:application) { Doorkeeper::Application.new(id: 123, name: 'Web', website: website) }
  let(:website) { nil }

  it 'keeps the generator identity and name when the website is missing' do
    expect(json).to include(
      'id' => generator_url(application),
      'type' => 'Application',
      'name' => 'Web',
      'url' => nil
    )
  end

  [
    'https://app.joinmastodon.org/ios',
    'https://covelline.com/feather/',
    'http://example.com:8080/app?source=web#about',
    'HTTPS://Example.COM/App',
    'https://example.com/app%20name?q=%2f',
    'https://例え.テスト/アプリ',
    'https://[2001:db8::1]/app',
  ].each do |value|
    context "with a valid HTTP(S) website #{value.inspect}" do
      let(:website) { value }

      it 'preserves the original URL without normalization' do
        expect(json).to include('url' => value)
      end
    end
  end

  [
    nil,
    '',
    " \t\r\n",
    './',
    '/',
    '../app',
    '//example.com/app',
    'example.com/app',
    'ftp://example.com/app',
    'javascript:alert(1)',
    'https:',
    'https:/app',
    'https:///app',
    'https://',
    'https://:8080/app',
    'https://example.com:invalid/',
    'https://[::1',
    'https://2001:db8::1/app',
    'https://example.com/app name',
    "https://example.com/app\nname",
    'https://example.com/app\\name',
    'https://example.com/app|name',
    'https://example.com/app<name>',
    'https://example.com/%',
    'https://example.com/%2',
    'https://example.com/%GG',
  ].each do |value|
    context "with a missing or invalid website #{value.inspect}" do
      let(:website) { value }

      it 'keeps the URL key and serializes it as null' do
        expect(json).to have_key('url')
        expect(json['url']).to be_nil
      end
    end
  end
end
