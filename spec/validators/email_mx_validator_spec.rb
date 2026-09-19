# frozen_string_literal: true

require 'rails_helper'

describe EmailMxValidator do
  describe '#validate' do
    let(:user) { double(email: 'foo@example.com', sign_up_ip: '192.0.2.1', errors: double(add: nil)) }
    let(:now) { Time.utc(2026, 9, 19, 12, 0, 0) }

    around do |example|
      travel_to(now) { example.run }
    end

    def stub_resolver
      resolver = double
      allow(resolver).to receive(:timeouts=).and_return(nil)
      allow(Resolv::DNS).to receive(:open).and_yield(resolver)
      resolver
    end

    it 'does not add errors if there are no DNS records for an e-mail domain that is explicitly allowed' do
      old_whitelist = Rails.configuration.x.email_domains_whitelist
      Rails.configuration.x.email_domains_whitelist = 'example.com'

      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to_not have_received(:add)

      Rails.configuration.x.email_domains_whitelist = old_whitelist
    end

    it 'adds an error if there are no DNS records for the e-mail domain' do
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
    end

    it 'adds an error if a MX record exists but does not lead to an IP' do
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
    end

    it 'adds an error if the A record is blacklisted' do
      block = EmailDomainBlock.create!(domain: '1.2.3.4')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '1.2.3.4')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
      expect(block.history.get(now).accounts).to eq 1
    end

    it 'adds an error if the AAAA record is blacklisted' do
      block = EmailDomainBlock.create!(domain: 'fd00::1')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([double(address: 'fd00::1')])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
      expect(block.history.get(now).accounts).to eq 1
    end

    it 'adds an error if the MX record is blacklisted' do
      block = EmailDomainBlock.create!(domain: '2.3.4.5')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '2.3.4.5')])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
    end

    it 'adds an error if the MX IPv6 record is blacklisted' do
      block = EmailDomainBlock.create!(domain: 'fd00::2')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([double(address: 'fd00::2')])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
    end

    it 'adds an error if the MX hostname is blacklisted' do
      block = EmailDomainBlock.create!(domain: 'mail.example.com')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '2.3.4.5')])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([double(address: 'fd00::2')])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
      expect(block.history.get(now).accounts).to eq 1
    end

    it 'adds an error if the MX hostname is a subdomain of a blocked domain' do
      block = EmailDomainBlock.create!(domain: 'example.com')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '2.3.4.5')])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(block.history.get(now).uses).to eq 1
    end

    it 'does not add an error for an unblocked MX hostname and IP' do
      unrelated = EmailDomainBlock.create!(domain: 'blocked.example')
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([double(exchange: 'mail.example.com')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '2.3.4.5')])
      allow(resolver).to receive(:getresources).with('mail.example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to_not have_received(:add)
      expect(unrelated.history.get(now).uses).to eq 0
    end

    it 'blocks a child IPv4 record created by DNS expansion' do
      parent = EmailDomainBlock.create!(domain: 'blocked.test')
      child  = EmailDomainBlock.create!(domain: '1.2.3.4', parent: parent)
      resolver = stub_resolver

      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::MX).and_return([])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::A).and_return([double(address: '1.2.3.4')])
      allow(resolver).to receive(:getresources).with('example.com', Resolv::DNS::Resource::IN::AAAA).and_return([])

      subject.validate(user)
      expect(user.errors).to have_received(:add)
      expect(child.history.get(now).uses).to eq 1
    end
  end
end
