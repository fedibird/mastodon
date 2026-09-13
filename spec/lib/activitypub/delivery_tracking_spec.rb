# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::DeliveryTracking do
  let(:handler) { class_double('FollowImport::TargetDeliveryTracker') }

  before do
    stub_const('ActivityPub::DeliveryTracking::HANDLERS', { 'follow_import_target' => 'FollowImport::TargetDeliveryTracker' })
    allow('FollowImport::TargetDeliveryTracker'.constantize).to receive(:delivered)
    allow('FollowImport::TargetDeliveryTracker'.constantize).to receive(:failed)
  end

  describe '.delivered' do
    it 'routes to the registered handler with the id' do
      described_class.delivered({ 'type' => 'follow_import_target', 'id' => 42 })
      expect(FollowImport::TargetDeliveryTracker).to have_received(:delivered).with(42)
    end

    it 'accepts symbol keys' do
      described_class.delivered({ type: 'follow_import_target', id: 7 })
      expect(FollowImport::TargetDeliveryTracker).to have_received(:delivered).with(7)
    end
  end

  describe '.failed' do
    it 'routes to the registered handler with the id' do
      described_class.failed({ 'type' => 'follow_import_target', 'id' => 9 })
      expect(FollowImport::TargetDeliveryTracker).to have_received(:failed).with(9)
    end
  end

  describe 'safety' do
    it 'ignores unknown tracking types' do
      described_class.delivered({ 'type' => 'nope', 'id' => 1 })
      expect(FollowImport::TargetDeliveryTracker).not_to have_received(:delivered)
    end

    it 'ignores malformed tracking metadata' do
      expect { described_class.delivered(nil) }.not_to raise_error
      expect { described_class.delivered('garbage') }.not_to raise_error
      expect { described_class.delivered({ 'type' => 'follow_import_target' }) }.not_to raise_error
      expect(FollowImport::TargetDeliveryTracker).not_to have_received(:delivered)
    end

    it 'swallows handler errors so a delivery is never broken' do
      allow(FollowImport::TargetDeliveryTracker).to receive(:delivered).and_raise(StandardError, 'boom')
      expect { described_class.delivered({ 'type' => 'follow_import_target', 'id' => 1 }) }.not_to raise_error
    end
  end
end
