# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Scheduler::Trends::ReviewNotificationsScheduler do
  it 'requests trend review once' do
    expect(Trends).to receive(:request_review!).once

    described_class.new.perform
  end
end
