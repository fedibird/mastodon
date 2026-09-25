# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StatusEdit::PreservedMediaAttachment do
  let(:media) { Fabricate(:media_attachment, description: 'after edit') }
  let(:wrapper) do
    described_class.new(media_attachment: media, description: 'before edit')
  end

  it 'delegates routing identity to the underlying media attachment' do
    expect(wrapper.id).to eq media.id
    expect(wrapper.to_param).to eq media.to_param
    expect(Rails.application.routes.url_helpers.medium_path(wrapper)).to eq "/media/#{media.to_param}"
  end

  it 'keeps the description stored on the edit snapshot' do
    expect(wrapper.description).to eq 'before edit'
    expect(wrapper.description).not_to eq media.description
  end
end
