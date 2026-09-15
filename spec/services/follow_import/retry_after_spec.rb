# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::RetryAfter do
  def response_with(value)
    instance_double(HTTP::Response, headers: { 'Retry-After' => value })
  end

  it 'parses delta-seconds' do
    expect(described_class.seconds_from(response_with('30'))).to eq 30
  end

  it 'parses an HTTP-date into a non-negative second count' do
    freeze_time do
      header = 90.seconds.from_now.httpdate
      expect(described_class.seconds_from(response_with(header))).to be_within(1).of(90)
    end
  end

  it 'returns nil when the header is missing or not safely parseable' do
    expect(described_class.seconds_from(response_with(nil))).to be_nil
    expect(described_class.seconds_from(response_with('soon'))).to be_nil
    expect(described_class.seconds_from(nil)).to be_nil
  end
end
