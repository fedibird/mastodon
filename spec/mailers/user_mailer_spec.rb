# frozen_string_literal: true

require 'rails_helper'

describe UserMailer, type: :mailer do
  let(:receiver) { Fabricate(:user) }

  def stub_webpacker_manifest
    manifest = Webpacker.instance.manifest
    resolver = ->(name, **opts) { opts[:with_integrity] ? ["/packs-test/#{name}", nil] : "/packs-test/#{name}" }
    allow(manifest).to receive(:lookup!, &resolver)
    allow(manifest).to receive(:lookup, &resolver)
  end

  shared_examples 'localized subject' do |*args, **kwrest|
    it 'renders subject localized for the locale of the receiver' do
      locale = I18n.available_locales.sample
      receiver.update!(locale: locale)
      expect(mail.subject).to eq I18n.t(*args, **kwrest.merge(locale: locale))
    end

    it 'renders subject localized for the default locale if the locale of the receiver is unavailable' do
      receiver.update!(locale: nil)
      expect(mail.subject).to eq I18n.t(*args, **kwrest.merge(locale: I18n.default_locale))
    end
  end

  describe 'follow_import_finished' do
    let(:batch)   { instance_double(FollowImportBatch) }
    let(:summary) { { 'total' => 5, 'processed' => 4, 'waiting' => 1, 'failed' => 2, 'completed' => false } }
    let(:mail)    { UserMailer.follow_import_finished(receiver, batch, summary) }

    # Render the mailer layout without the compiled webpack manifest (not built
    # in this test env; CI precompiles packs). Stub the manifest lookup at its
    # single root so every pack helper resolves to a dummy path.
    before { stub_webpacker_manifest }

    it 'renders the follow-import completion email' do
      receiver.update!(locale: nil)
      expect(mail.body.encoded).to include I18n.t('user_mailer.follow_import_finished.title')
      expect(mail.body.encoded).to include I18n.t('user_mailer.follow_import_finished.summary.processed', count: 4, total: 5)
    end

    include_examples 'localized subject', 'user_mailer.follow_import_finished.subject'
  end

  describe 'confirmation_instructions' do
    let(:mail) { UserMailer.confirmation_instructions(receiver, 'spec') }

    it 'renders confirmation instructions' do
      receiver.update!(locale: nil)
      expect(mail.body.encoded).to include I18n.t('devise.mailer.confirmation_instructions.title')
      expect(mail.body.encoded).to include 'spec'
      expect(mail.body.encoded).to include Rails.configuration.x.local_domain
    end

    include_examples 'localized subject',
                     'devise.mailer.confirmation_instructions.subject',
                     instance: Rails.configuration.x.local_domain
  end

  describe 'reconfirmation_instructions' do
    let(:mail) { UserMailer.confirmation_instructions(receiver, 'spec') }

    it 'renders reconfirmation instructions' do
      receiver.update!(email: 'new-email@example.com', locale: nil)
      expect(mail.body.encoded).to include I18n.t('devise.mailer.reconfirmation_instructions.title')
      expect(mail.body.encoded).to include 'spec'
      expect(mail.body.encoded).to include Rails.configuration.x.local_domain
      expect(mail.subject).to eq I18n.t('devise.mailer.reconfirmation_instructions.subject',
                                        instance: Rails.configuration.x.local_domain,
                                        locale: I18n.default_locale)
    end
  end

  describe 'reset_password_instructions' do
    let(:mail) { UserMailer.reset_password_instructions(receiver, 'spec') }

    it 'renders reset password instructions' do
      receiver.update!(locale: nil)
      expect(mail.body.encoded).to include I18n.t('devise.mailer.reset_password_instructions.title')
      expect(mail.body.encoded).to include 'spec'
    end

    include_examples 'localized subject',
                     'devise.mailer.reset_password_instructions.subject'
  end

  describe 'password_change' do
    let(:mail) { UserMailer.password_change(receiver) }

    it 'renders password change notification' do
      receiver.update!(locale: nil)
      expect(mail.body.encoded).to include I18n.t('devise.mailer.password_change.title')
    end

    include_examples 'localized subject',
                     'devise.mailer.password_change.subject'
  end

  describe 'email_changed' do
    let(:mail) { UserMailer.email_changed(receiver) }

    it 'renders email change notification' do
      receiver.update!(locale: nil)
      expect(mail.body.encoded).to include I18n.t('devise.mailer.email_changed.title')
    end

    include_examples 'localized subject',
                     'devise.mailer.email_changed.subject'
  end
end
