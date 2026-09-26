# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::AdminSettings do
  let(:account) { Fabricate(:account) }

  def form(status_page_url)
    described_class.new(
      site_contact_username: account.username,
      site_contact_email: 'admin@example.com',
      status_page_url: status_page_url
    )
  end

  it 'accepts an https status page URL' do
    settings = form('https://status.example.com')

    expect(settings).to be_valid
    expect(settings.errors[:status_page_url]).to be_empty
  end

  it 'accepts a blank status page URL' do
    settings = form('')

    expect(settings).to be_valid
    expect(settings.errors[:status_page_url]).to be_empty
  end

  it 'rejects a status page URL that is not a URL' do
    settings = form('not a url')

    expect(settings).not_to be_valid
    expect(settings.errors[:status_page_url]).to be_present
  end
end
