# frozen_string_literal: true

require 'rails_helper'

describe ScopeTransformer do
  subject { described_class.new.apply(ScopeParser.new.parse(input)) }

  {
    'read' => [nil, 'all', 'read'],
    'write' => [nil, 'all', 'write'],
    'follow' => [nil, 'follow', 'read/write'],
    'push' => [nil, 'push', 'read/write'],
    'crypto' => [nil, 'crypto', 'read/write'],
    'admin:read' => ['admin', 'all', 'read'],
    'admin:write' => ['admin', 'all', 'write'],
    'admin:read:accounts' => ['admin', 'accounts', 'read'],
    'read:accounts' => [nil, 'accounts', 'read'],
    'admin:read:domain_blocks' => ['admin', 'domain_blocks', 'read'],
    'admin:write:email_domain_blocks' => ['admin', 'email_domain_blocks', 'write'],
  }.each do |scope_string, (namespace, term, access)|
    context "with #{scope_string}" do
      let(:input) { scope_string }

      it 'parses namespace, term, access, and key' do
        expect(subject.namespace).to eq namespace
        expect(subject.term).to eq term
        expect(subject.access).to eq access
        expect(subject.key).to eq [namespace, term].compact.join('/')
      end
    end
  end
end
