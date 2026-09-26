# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Form::AdminSettings do
  let(:account) { Fabricate(:account) }
  let(:file) { fixture_file_upload('avatar.gif', 'image/gif') }

  def save_upload(key)
    upload = instance_double(SiteUpload, update: true)
    relation = instance_double(ActiveRecord::Relation)
    allow(SiteUpload).to receive(:where).with(var: key).and_return(relation)
    allow(relation).to receive(:first_or_initialize).with(var: key).and_return(upload)

    form = described_class.new(
      site_contact_username: account.username,
      site_contact_email: 'admin@example.com',
      key => file
    )

    expect(form.save).to be true
    expect(upload).to have_received(:update).with(file: file)
  end

  it 'creates or updates the favicon site upload' do
    save_upload(:favicon)
  end

  it 'creates or updates the app icon site upload' do
    save_upload(:app_icon)
  end

  it 'keeps thumbnail and mascot as upload keys' do
    expect(described_class::UPLOAD_KEYS).to include(:thumbnail, :mascot, :favicon, :app_icon)
  end
end
