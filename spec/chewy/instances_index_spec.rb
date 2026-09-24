# frozen_string_literal: true

require 'rails_helper'

describe InstancesIndex do
  describe '.compose' do
    it 'indexes domain and accounts_count' do
      Fabricate(:account, domain: 'indexed.example', username: 'one')
      Fabricate(:account, domain: 'indexed.example', username: 'two')
      Instance.refresh

      document = described_class.compose(Instance.find('indexed.example'))

      expect(document['domain']).to eq 'indexed.example'
      expect(document['accounts_count']).to eq 2
    end
  end
end
