# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::RevalidationEligibility do
  it 'keeps remote Lemmy and PieFed communities eligible for admin revalidation' do
    %w(lemmy piefed).each do |software|
      account = Fabricate(
        :account,
        username: 'technology',
        domain: "#{software}.example",
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{software}.example/c/technology",
        inbox_url: "https://#{software}.example/c/technology/inbox"
      )

      expect(described_class.eligible?(account)).to be true
    end
  end
end
