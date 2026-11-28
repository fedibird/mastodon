# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupDirectory::Parameters do
  def parse(params)
    described_class.parse!(params)
  end

  it 'parses handles, one-character usernames, and empty searches' do
    expect(parse(q: '  book  ').query).to eq('book')
    expect(parse(q: '  book  ')).to be_substring
    expect(parse(q: '   ').query).to be_nil
    expect(parse(q: 'a')).to be_exact
    expect(parse(q: 'a').acct).to include(username: 'a', domain_constrained: false)
    expect(parse(q: '猫')).to be_empty_result
    expect(parse(q: '@Walkers').acct).to include(username: 'walkers', domain_constrained: false)
    remote = parse(q: '@walkers@LEMMY.EXAMPLE')
    expect(remote.acct).to include(username: 'walkers', domain: 'lemmy.example', domain_constrained: true)
    local = parse(q: "@camera@#{Rails.configuration.x.local_domain}")
    expect(local.acct).to include(username: 'camera', domain: '', domain_constrained: true)
    expect(parse(q: 'walkers@https://evil.example')).to be_rejected_handle
    expect(parse({})).to have_attributes(scope: 'all', order: 'active', offset: 0, language: nil, software: nil)
  end

  it 'canonicalizes filters and rejects invalid input before a search' do
    expect(parse(language: 'en-us').language).to eq('en-US')
    expect(parse(language: 'unset').language).to eq(:unset)
    expect(parse(language: 'all').language).to be_nil
    expect(parse(software: 'Lemmy').software).to eq('lemmy')
    expect(parse(scope: 'LOCAL').scope).to eq('local')
    expect(parse(order: 'new').order).to eq('new')
    expect(parse(offset: '15').offset).to eq(15)
    expect(parse(offset: '   ').offset).to eq(0)

    [
      { q: 'a' * 101 },
      { q: ['array'] },
      { software: 'lemmy;drop' },
      { scope: 'everything' },
      { order: 'random' },
      { offset: '-1' },
      { offset: '10001' },
      { offset: ['1'] },
      { language: '<script>' },
    ].each do |params|
      expect { parse(params) }.to raise_error(Mastodon::InvalidParameterError), params.inspect
    end
  end
end
