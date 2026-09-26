# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AboutController, type: :controller do
  render_views

  before { Rails.cache.clear }

  it 'uses custom favicon and app icon links and omits the mask icon' do
    favicon = SiteUpload.new(var: 'favicon')
    app_icon = SiteUpload.new(var: 'app_icon')
    allow(favicon).to receive_message_chain(:file, :url).and_return('/system/favicon.png')
    allow(app_icon).to receive_message_chain(:file, :url).and_return('/system/app-icon.png')
    allow(Rails.cache).to receive(:fetch).and_call_original
    allow(Rails.cache).to receive(:fetch).with('site_uploads/favicon').and_yield
    allow(Rails.cache).to receive(:fetch).with('site_uploads/app_icon').and_yield
    allow(SiteUpload).to receive(:find_by).and_call_original
    allow(SiteUpload).to receive(:find_by).with(var: 'favicon').and_return(favicon)
    allow(SiteUpload).to receive(:find_by).with(var: 'app_icon').and_return(app_icon)

    get :show

    expect(response.body).to include('rel="icon"', '/system/favicon.png', 'image/png', '16x16', '32x32', '48x48')
    expect(response.body).to include('rel="apple-touch-icon"', '/system/app-icon.png', '180x180')
    expect(response.body).not_to include('rel="mask-icon"')
    expect(response.body).not_to include('msapplication-config')
    expect(response.body).not_to include('/favicon.ico')
    expect(response.body).not_to include('/favicon-dev.ico')
    expect(response.body).not_to include('image/x-icon')
    expect(response.body).not_to include('/icons/favicon-')
  end

  it 'keeps the standard Fedibird icons when nothing is uploaded' do
    allow(SiteUpload).to receive(:find_by).and_call_original

    get :show

    expect(response.body).to include(
      'rel="icon"',
      'image/png',
      '/icons/favicon-16x16.png',
      '/icons/favicon-32x32.png',
      '/icons/favicon-48x48.png'
    )
    expect(response.body).to include('rel="apple-touch-icon"', '/apple-touch-icon.png')
    expect(response.body).to include('rel="mask-icon"', '/mask-icon.svg')
    expect(response.body).not_to include('/favicon.ico')
    expect(response.body).not_to include('/favicon-dev.ico')
    expect(response.body).not_to include('image/x-icon')
    expect(response.body).not_to include('msapplication-config')
  end
end
