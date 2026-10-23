# frozen_string_literal: true

require 'rails_helper'

describe ExternalBridge::LinkSharing::ArticleURL do
  def normalize(value)
    described_class.normalize!(value)
  end

  def reject(value)
    described_class.normalize!(value)
  rescue ExternalBridge::Error => e
    e.code
  end

  it 'accepts a path permalink and a public id query' do
    expect(normalize('https://example.com/posts/hello')).to eq('https://example.com/posts/hello')
    expect(normalize('HTTPS://Example.COM:443/posts/hello#frag')).to eq('https://example.com/posts/hello')
    expect(normalize('https://example.com/?p=123')).to eq('https://example.com?p=123')
    expect(normalize('https://example.com/article?id=42')).to eq('https://example.com/article?id=42')
    expect(normalize('https://example.com/article?name=hello-world')).to eq('https://example.com/article?name=hello-world')
    expect(normalize('https://example.com/a?p=%31%32%33')).to eq('https://example.com/a?p=123')
    expect(normalize('https://example.com/a?id=42&p=7')).to eq('https://example.com/a?id=42&p=7')
  end

  it 'rejects credentials, private literals, and encoded secret names' do
    expect(reject('https://user:pass@example.com/posts/1')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?token=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?API_KEY=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?signature=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?%74oken=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?%2574oken=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?p=123&token=abc')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?p=123&preview=1')).to eq('authenticated_source_rejected')
    expect(reject('https://example.com/a?q=%')).to eq('authenticated_source_rejected')
    expect(reject('http://127.0.0.1/posts/1')).to eq('private_address')
    expect(reject('http://10.1.2.3/posts/1')).to eq('private_address')
    expect(reject('http://[::1]/posts/1')).to eq('private_address')
  end

  it 'does not loosen the feed fetch URL rules' do
    expect { ExternalBridge::RSS::CanonicalURL.normalize!('https://example.com/?p=123') }
      .to raise_error(ExternalBridge::Error) { |error| expect(error.code).to eq('authenticated_source_rejected') }
    expect(ExternalBridge::RSS::CanonicalURL.normalize!('https://feeds.example/listed.xml?format=rss'))
      .to eq('https://feeds.example/listed.xml?format=rss')
  end
end
