# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessStatusReferenceService do
  describe '#call' do
    it 'does not create an immediate reference to an aggregator that claims the linked article URL' do
      url = 'https://publisher.com/articles/reference-only'
      aggregator = Fabricate(:account, domain: 'aggregator.test', username: 'relay')
      Fabricate(:status, account: aggregator, uri: 'https://aggregator.test/objects/reference-only', url: url)
      source = Fabricate(:status, account: Fabricate(:account), text: "Read this: #{url}")

      publisher_node = double('node', domain: 'publisher.com')
      allow(Node).to receive(:resolve_domain).with('publisher.com').and_return(publisher_node)
      allow(StatusReferenceResolveWorker).to receive(:push_bulk)
      service = described_class.new
      allow(service).to receive(:redis).and_return(double('redis', sadd: true))

      # Use an explicit candidate to exercise AP identity resolution independent
      # of TwitterText's TLD recognition in the local text scanner.
      expect { service.call(source, urls: [url]) }.not_to change(StatusReference, :count)
      expect(StatusReferenceResolveWorker).to have_received(:push_bulk)
    end
  end
end
