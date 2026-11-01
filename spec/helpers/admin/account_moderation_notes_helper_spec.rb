# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::AccountModerationNotesHelper, type: :helper do
  include AccountsHelper

  describe '#admin_account_link_to' do
    context 'account is nil' do
      let(:account) { nil }

      it 'returns nil' do
        expect(helper.admin_account_link_to(account)).to be_nil
      end
    end

    context 'with account' do
      let(:account) { Fabricate(:account) }

      it 'calls #link_to' do
        expect(helper).to receive(:link_to).with(
          admin_account_path(account.id),
          class: name_tag_classes(account),
          title: account.acct
        )

        helper.admin_account_link_to(account)
      end
    end
  end

  describe '#admin_account_inline_link_to' do
    context 'account is nil' do
      let(:account) { nil }

      it 'returns nil' do
        expect(helper.admin_account_inline_link_to(account)).to be_nil
      end
    end

    context 'with account' do
      let(:account) { Fabricate(:account) }

      it 'calls #link_to' do
        expect(helper).to receive(:link_to).with(
          admin_account_path(account.id),
          class: name_tag_classes(account, true),
          title: account.acct
        )

        helper.admin_account_inline_link_to(account)
      end
    end
  end

  describe 'deleted account decoration for managed Groups' do
    let(:group) { Fabricate(:account, username: 'adminmanagedgroup', actor_type: 'Group') }
    let(:creation_request) do
      GroupCreationRequest.create!(
        requester_account: Fabricate(:user).account,
        username: group.username,
        display_name: 'Managed group'
      )
    end

    before do
      ManagedGroup.create!(account: group, creation_request: creation_request, origin: :approved_request)
    end

    it 'does not strike through either link variant for an active Group without a login' do
      expect(helper.admin_managed_group_without_login?(group)).to be true
      expect(helper.admin_deleted_local_account?(group)).to be false

      expect(Nokogiri::HTML.fragment(helper.admin_account_link_to(group)).at_css('a')['class']).to eq('name-tag')
      expect(Nokogiri::HTML.fragment(helper.admin_account_inline_link_to(group)).at_css('a')['class']).to eq('inline-name-tag')
    end

    it 'still marks a suspended managed Group as suspended' do
      group.update!(suspended_at: Time.current)

      expect(Nokogiri::HTML.fragment(helper.admin_account_link_to(group)).at_css('a')['class']).to eq('name-tag suspended')
    end
  end

  describe 'legacy local account decoration' do
    it 'retains the deleted decoration on a local Person without a User' do
      account = Fabricate(:account)

      expect(helper.admin_deleted_local_account?(account)).to be true
      expect(Nokogiri::HTML.fragment(helper.admin_account_link_to(account)).at_css('a')['class']).to eq('name-tag suspended')
    end

    it 'does not consider an unmanaged local Group with no User a live managed Group' do
      account = Fabricate(:account, actor_type: 'Group')

      expect(helper.admin_deleted_local_account?(account)).to be true
    end

    it 'does not treat a remote Group as a deleted local account' do
      account = Fabricate(:account, actor_type: 'Group', domain: 'remote.example', uri: 'https://remote.example/groups/test')

      expect(helper.admin_deleted_local_account?(account)).to be false
    end

    it 'does not treat a legacy local Group with a User as deleted' do
      account = Fabricate(:user).account
      account.update!(actor_type: 'Group')

      expect(helper.admin_deleted_local_account?(account)).to be false
    end
  end
end
