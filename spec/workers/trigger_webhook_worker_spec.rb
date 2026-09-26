# frozen_string_literal: true

require 'rails_helper'

describe TriggerWebhookWorker do
  let(:worker) { described_class.new }
  let(:status) { Fabricate(:status) }

  it 'reloads the object and calls WebhookService' do
    created = status
    service = instance_double(WebhookService, call: nil)
    allow(WebhookService).to receive(:new).and_return(service)

    worker.perform('status.created', 'Status', created.id)

    expect(service).to have_received(:call).with('status.created', created)
  end

  it 'finishes normally when the object has been deleted' do
    expect(worker.perform('status.created', 'Status', -1)).to be true
  end
end
