# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'settings navigation', type: :helper do
  def navigation_for(user)
    I18n.with_locale(user.locale.presence || :en) do
      helper.define_singleton_method(:current_user) { user }
      helper.define_singleton_method(:current_account) { user.account }
      allow(helper.controller).to receive(:view_context).and_return(helper)
      helper.render_navigation(expand_all: true)
    end
  end

  it 'links External services under Preferences' do
    user = Fabricate(:user, locale: 'en')
    html = Nokogiri::HTML.fragment(navigation_for(user))
    link = html.at_css('li#preferences li#external_services a')

    expect(link['href']).to eq(helper.settings_external_services_url)
    expect(link.text).to include('External services')
    expect(link.at_css('.fa-plug')).to be_present
  end

  it 'uses the Japanese label' do
    user = Fabricate(:user, locale: 'ja')
    html = Nokogiri::HTML.fragment(navigation_for(user))
    link = html.at_css('li#preferences li#external_services a')

    expect(link.text).to include('外部サービス')
  end
end
