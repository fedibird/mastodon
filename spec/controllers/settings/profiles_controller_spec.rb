require 'rails_helper'

RSpec.describe Settings::ProfilesController, type: :controller do
  render_views

  before do
    @user = Fabricate(:user)
    sign_in @user, scope: :user
  end

  describe "GET #show" do
    it "returns http success" do
      get :show
      expect(response).to have_http_status(200)
    end

    it 'adds the static emoji picker only to emoji-capable profile fields' do
      get :show
      document = Nokogiri::HTML(response.body)
      picked = %w(account_display_name account_note account_followed_message).map { |id| document.at_css("##{id}") }
      pairs = document.css('input[name^="account[fields_attributes]"][name$="[name]"], input[name^="account[fields_attributes]"][name$="[value]"]')

      expect(picked + pairs).to all(satisfy { |field| field['data-emoji-picker'] == 'true' })
      expect(pairs.size).to eq(Account::DEFAULT_FIELDS_SIZE * 2)
      display_name = document.at_css('#account_display_name')
      expect([display_name['maxlength'], display_name['data-default']]).to eq(['500', @user.account.username])
      expect(document.at_css('#account_note')['maxlength']).to eq('500')
      expect(document.at_css('#account_followed_message')['maxlength']).to eq('500')
      expect(pairs).to all(satisfy { |field| field['maxlength'] == '255' })
      expect(document.at_css('#account_location')['data-emoji-picker']).to be_nil
    end

    it 'gives profile fields and verification their own full-width sections' do
      get :show
      document = Nokogiri::HTML(response.body)
      fields = document.at_css('.profile-fields')
      verification = document.at_css('.profile-verification')

      expect(fields).to be_present
      expect(verification).to be_present
      expect(fields['class']).not_to include('fields-row__column-6')
      expect(verification['class']).not_to include('fields-row__column-6')
      expect(fields.at_css('.row input[name$="[name]"]')).to be_present
      expect(fields.at_css('.row input[name$="[value]"]')).to be_present
      expect(verification.at_css('.input-copy input')).to be_present
      expect(fields.ancestors.none? { |node| node['class'].to_s.split.include?('fields-row') }).to be true
      expect(verification.ancestors.none? { |node| node['class'].to_s.split.include?('fields-row') }).to be true
    end
  end

  describe 'PUT #update' do
    it 'updates the user profile' do
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
      account = Fabricate(:account, user: @user, display_name: 'Old name')

      put :update, params: { account: { display_name: 'New name' } }
      expect(account.reload.display_name).to eq 'New name'
      expect(response).to redirect_to(settings_profile_path)
      expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(account.id)
    end

    it 'stores emoji shortcodes as plain profile text' do
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
      account = @user.account
      put :update, params: { account: { display_name: 'Fedibird :fedibird:', note: 'Hello :fedibird:', followed_message: 'Thanks :fedibird:', fields_attributes: { '0' => { name: 'Work :fedibird:', value: 'https://example.test :fedibird:' } } } }
      account.reload
      expect([account.display_name, account.note, account.followed_message, account.fields.first.name, account.fields.first.value]).to eq(['Fedibird :fedibird:', 'Hello :fedibird:', 'Thanks :fedibird:', 'Work :fedibird:', 'https://example.test :fedibird:'])
    end
  end

  describe 'PUT #update with new profile image' do
    it 'updates profile image' do
      allow(ActivityPub::UpdateDistributionWorker).to receive(:perform_async)
      account = Fabricate(:account, user: @user, display_name: 'AvatarTest')
      expect(account.avatar.instance.avatar_file_name).to be_nil

      put :update, params: { account: { avatar: fixture_file_upload('avatar.gif', 'image/gif') } }
      expect(response).to redirect_to(settings_profile_path)
      expect(account.reload.avatar.instance.avatar_file_name).not_to be_nil
      expect(ActivityPub::UpdateDistributionWorker).to have_received(:perform_async).with(account.id)
    end
  end
end
