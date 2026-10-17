# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Searchability visibility guards' do
  let(:account) { Fabricate(:user).account }

  {
    public: { public: 'public', private: 'private', direct: 'direct' },
    unlisted: { public: 'private', private: 'private', direct: 'direct' },
    private: { public: 'private', private: 'private', direct: 'direct' },
    mutual: { public: 'mutual', private: 'mutual', direct: 'mutual' },
    limited: { public: 'limited', private: 'limited', direct: 'limited' },
    direct: { public: 'direct', private: 'direct', direct: 'direct' },
    personal: { public: 'personal', private: 'personal', direct: 'personal' },
  }.each do |visibility, searches|
    searches.each do |desired, expected|
      it "caps #{visibility}/#{desired} at the posting service and model boundaries" do
        status = PostStatusService.new.call(account, text: 'search visibility test', visibility: visibility, searchability: desired)
        model_status = Fabricate(:status, account: account, visibility: visibility, searchability: desired)

        expect(status.reload.searchability).to eq expected
        # The model preserves the full enum; the service also maps unlisted to private.
        model_expected = visibility == :unlisted && desired == :public ? 'unlisted' : expected
        expect(model_status.reload.searchability).to eq model_expected
      end
    end
  end
end
