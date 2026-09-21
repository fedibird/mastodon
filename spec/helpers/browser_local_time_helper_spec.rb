# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BrowserLocalTimeHelper, type: :helper do
  let(:instant) { Time.utc(2026, 9, 21, 7, 30, 0) }

  def time_tag(html)
    Nokogiri::HTML.fragment(html).at_css('time.formatted')
  end

  it 'renders an empty time.formatted tag with a canonical ISO8601 datetime' do
    html = helper.formatted_browser_local_time(instant)
    node = time_tag(html)

    expect(node).to be_present
    expect(node.text).to eq ''
    expect(node['datetime']).to eq instant.iso8601
    expect(Time.iso8601(node['datetime'])).to eq instant
  end

  it 'parses an ISO8601 string without shifting the absolute instant' do
    html = helper.formatted_browser_local_time(instant.iso8601)
    node = time_tag(html)

    expect(Time.iso8601(node['datetime'])).to eq instant
    expect(node['datetime']).to_not include('+09:00')
  end

  it 'returns nil for blank or unparseable values' do
    expect(helper.formatted_browser_local_time(nil)).to be_nil
    expect(helper.formatted_browser_local_time('')).to be_nil
    expect(helper.formatted_browser_local_time('not-a-timestamp')).to be_nil
  end
end
