# frozen_string_literal: true

require 'rails_helper'

describe GroupDirectory::Languages do
  before { load Rails.root.join('db', 'seeds', '03_roles.rb') }

  let(:requester) { Fabricate(:user) }
  let(:owner) { Fabricate(:user) }
  let(:reviewer) { user_with_role('Owner') }
  let(:request) do
    GroupCreationRequest.create!(
      requester_account: requester.account,
      username: 'langgroup',
      display_name: 'Language Group',
      note: 'A place to talk'
    )
  end
  let(:group) { Fabricate(:account, username: request.username, actor_type: 'Group', user: Fabricate(:user, approved: true, confirmed_at: 10.days.ago)) }
  let!(:managed) { ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request) }

  def assign_owner
    GroupRoleAssignment.create!(
      group_account: group,
      member_account: owner.account,
      role: :owner,
      granted_by_account: reviewer.account,
      granted_at: Time.current
    )
  end

  it 'stores canonical tags for the owner and does not rewrite the creation request' do
    assign_owner

    expect(described_class.replace!(account: group, tags: ['JA', 'en-us', 'ja'], actor: owner.account)).to eq(['ja', 'en-US'])
    expect(group.group_languages.order(:tag).pluck(:tag)).to eq(['en-US', 'ja'])
    expect(request.reload.username).to eq('langgroup')
    expect(request.note).to eq('A place to talk')
    expect(request).to be_pending
    expect(request.attributes.keys).not_to include('language', 'languages')

    expect(described_class.replace!(account: group, tags: [], actor: owner.account)).to eq([])
    expect(group.group_languages).to be_empty
  end

  it 'lets a server administrator write and refuses everyone else, including remote groups' do
    assign_owner
    stranger = Fabricate(:user)
    moderator = Fabricate(:user)
    GroupRoleAssignment.create!(
      group_account: group,
      member_account: moderator.account,
      role: :moderator,
      granted_by_account: reviewer.account,
      granted_at: Time.current
    )
    admin = user_with_role('Admin')

    expect { described_class.replace!(account: group, tags: ['ja'], actor: stranger.account) }.to raise_error(Mastodon::NotPermittedError)
    expect { described_class.replace!(account: group, tags: ['ja'], actor: moderator.account) }.to raise_error(Mastodon::NotPermittedError)
    expect(described_class.replace!(account: group, tags: ['zh-hans'], actor: admin.account)).to eq(['zh-Hans'])

    remote = Fabricate(:account, username: 'remotegroup', domain: 'lemmy.example', actor_type: 'Group')
    expect { described_class.replace!(account: remote, tags: ['ja'], actor: admin.account) }.to raise_error(Mastodon::NotPermittedError)
    expect(GroupLanguage.where(account: remote)).to be_empty
    expect(described_class.canonicalize('zh-Hans')).to eq('zh-Hans')
    expect(described_class.canonicalize('es-419')).to eq('es-419')
    expect(described_class.canonicalize('zh-Hans-CN')).to eq('zh-Hans-CN')
    expect(described_class.canonicalize('i-klingon')).to be_nil
    expect(described_class.canonicalize('en-US-u-co-phonebk')).to be_nil
    expect { described_class.replace!(account: group, tags: ['not a language'], actor: owner.account) }.to raise_error(Mastodon::ValidationError)
    expect { described_class.replace!(account: group, tags: ['i-enochian'], actor: owner.account) }.to raise_error(Mastodon::ValidationError)
    expect { described_class.replace!(account: group, tags: %w(aa ab ae af ak am an ar as), actor: owner.account) }.to raise_error(Mastodon::ValidationError)
    expect(GroupLanguage.where(account: Fabricate(:account, username: 'personlang'))).to be_empty
    expect(GroupLanguage.new(account: Fabricate(:account, username: 'notgroup'), tag: 'ja')).not_to be_valid
  end
end
