# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Following CSV notify_reblogs' do
  let(:account) { Fabricate(:account, locked: false) }
  let(:alice)   { Fabricate(:account, username: 'alice', locked: false) }
  let(:carol)   { Fabricate(:account, username: 'carol', locked: true) }

  def csv_file(text)
    file = Tempfile.new(['following', '.csv'])
    file.write(text)
    file.rewind
    file
  end

  def import_csv(text, overwrite: false)
    Import.create!(account: account, type: 'following', data: csv_file(text), overwrite: overwrite)
  end

  def relationship(target)
    Follow.find_by(account: account, target_account: target) ||
      FollowRequest.find_by(account: account, target_account: target)
  end

  def settings(target)
    relationship(target).attributes.slice('show_reblogs', 'notify', 'notify_reblogs', 'languages', 'delivery')
  end

  def capture_relationship_jobs
    captured = []
    run = lambda do |args|
      captured << args.map { |arg| arg.is_a?(Hash) ? arg.deep_dup : arg }
      Import::RelationshipWorker.new.perform(*args)
    end
    allow(Import::RelationshipWorker).to receive(:perform_async) { |*args| run.call(args) }
    allow(Import::RelationshipWorker).to receive(:push_bulk) do |items, &block|
      items.each { |item| run.call(block.call(item)) }
    end
    captured
  end

  before do
    stub_request(:post, //)
  end

  describe 'batch execution' do
    it 'imports a six-column CSV through the batch worker and stores real booleans' do
      alice
      carol
      captured = capture_relationship_jobs

      text = <<~CSV
        Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home
        alice,false,true,true,"en, ja",false
        carol,true,false,false,,true
      CSV
      ImportService.new.call(import_csv(text))

      expect(settings(alice)).to eq(
        'show_reblogs' => false, 'notify' => true, 'notify_reblogs' => true, 'languages' => %w(en ja), 'delivery' => false
      )
      expect(account.requested?(carol)).to be true
      expect(settings(carol)).to eq(
        'show_reblogs' => true, 'notify' => false, 'notify_reblogs' => false, 'languages' => nil, 'delivery' => true
      )
      alice_args = captured.find { |args| args[1] == 'alice' }
      expect(alice_args[3]).to include('reblogs' => false, 'notify' => true, 'notify_reblogs' => true, 'languages' => %w(en ja), 'delivery' => false)
      expect(alice_args[3]['notify_reblogs']).to be true
    end

    it 'updates an existing follow and an unapproved follow request in merge mode' do
      account.follow!(alice, reblogs: true, notify: false, notify_reblogs: false, delivery: true, languages: ['en'])
      account.request_follow!(carol, reblogs: false, notify: true, notify_reblogs: true, delivery: false, languages: ['ja'])

      text = <<~CSV
        Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home
        alice,false,true,false,"ja",false
        carol,true,false,true,en,true
      CSV
      ImportService.new.call(import_csv(text))

      expect(account.following?(alice)).to be true
      expect(settings(alice)).to include('show_reblogs' => false, 'notify' => true, 'notify_reblogs' => false, 'delivery' => false, 'languages' => ['ja'])
      expect(account.requested?(carol)).to be true
      expect(settings(carol)).to include('show_reblogs' => true, 'notify' => false, 'notify_reblogs' => true, 'delivery' => true, 'languages' => ['en'])
    end

    it 'applies notify_reblogs on overwrite and unfollows accounts missing from the CSV' do
      extra = Fabricate(:account, username: 'extra')
      account.follow!(alice, notify_reblogs: false)
      account.follow!(extra)

      text = <<~CSV
        Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home
        alice,true,false,true,,true
      CSV
      ImportService.new.call(import_csv(text, overwrite: true))

      expect(account.following?(extra)).to be false
      expect(settings(alice)['notify_reblogs']).to be true
      expect(settings(alice)['notify']).to be false
      expect(settings(alice)['show_reblogs']).to be true
    end

    it 'sets notify_reblogs to false for a five-column CSV, a one-column CSV, and a blank cell' do
      account.follow!(alice, notify: true, notify_reblogs: true, reblogs: false, delivery: false, languages: ['en'])

      ImportService.new.call(import_csv("Account address,Show boosts,Notify on new posts,Languages,Delivery to home\nalice,false,true,en,false\n"))
      expect(settings(alice)).to include('notify_reblogs' => false, 'notify' => true, 'show_reblogs' => false, 'delivery' => false, 'languages' => ['en'])

      account.follow!(alice, notify_reblogs: true)
      ImportService.new.call(import_csv("Account address\nalice\n"))
      expect(settings(alice)['notify_reblogs']).to be false
      expect(settings(alice)['languages']).to eq ['en']

      account.follow!(alice, notify_reblogs: true, notify: true)
      ImportService.new.call(import_csv("Account address,Notify on new posts,Notify on boosts\nalice,false,\n"))
      expect(settings(alice)['notify']).to be false
      expect(settings(alice)['notify_reblogs']).to be false
    end
  end

  describe 'legacy direct import' do
    it 'passes cast notify_reblogs booleans to RelationshipWorker' do
      captured = capture_relationship_jobs
      allow(Moderation::FollowImportRecorder).to receive(:record_batch).and_return(nil)
      allow(FollowImport::BatchExecutionWorker).to receive(:perform_async)

      account.follow!(alice, notify_reblogs: true)
      carol
      text = <<~CSV
        Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home
        alice,false,true,false,"en, ja",false
        carol,true,false,true,,true
      CSV
      ImportService.new.call(import_csv(text))

      alice_options = captured.find { |args| args[1] == 'alice' }[3]
      carol_options = captured.find { |args| args[1] == 'carol' }[3]
      expect(alice_options).to include('reblogs' => false, 'notify' => true, 'notify_reblogs' => false, 'languages' => %w(en ja), 'delivery' => false)
      expect(alice_options['notify_reblogs']).to be false
      expect(carol_options['notify_reblogs']).to be true
      expect(alice_options).not_to have_key('import_batch_id')
      expect(settings(alice)['notify_reblogs']).to be false
      expect(settings(carol)['notify_reblogs']).to be true
      expect(account.requested?(carol)).to be true
    end
  end

  describe 'scheduler dispatch' do
    it 'enqueues the resolver options, including notify_reblogs, for a scheduler-owned batch' do
      alice
      text = <<~CSV
        Account address,Show boosts,Notify on new posts,Notify on boosts,Languages,Delivery to home
        alice,false,false,true,,false
      CSV
      import = import_csv(text)
      batch = FollowImportBatch.create!(
        subject: ModerationSubject.for_account!(account),
        import_id: import.id,
        imported_at: Time.now.utc,
        mode: :merge,
        dispatch_owner: :scheduler,
        dispatch_cohort: :operational,
        preflight_state: :ready,
        target_count: 1,
        resolved_target_count: 0,
        unresolved_target_count: 0
      )
      target = batch.targets.create!(target_key_hash: FollowImportTarget.key_hash('alice'), position: 0)
      entry = FollowImport::FairScheduler::Entry.new(
        owner_key: FollowImport::OwnerKey.for_batch(batch),
        batch_id: batch.id,
        target_id: target.id,
        position: 0,
        destination_domain: nil
      )

      captured = capture_relationship_jobs

      FollowImport::DispatchLease.with_lease do |handle|
        FollowImport::DispatchExecutor.new(lease: handle).execute([entry])
      end

      expect(captured.size).to eq 1
      expect(captured.first[1]).to eq 'alice'
      expect(captured.first[3]).to include(
        'reblogs' => false,
        'notify' => false,
        'notify_reblogs' => true,
        'delivery' => false,
        'import_batch_id' => batch.id,
        'follow_import_target_id' => target.id
      )
      expect(captured.first[3]['notify_reblogs']).to be true
      expect(settings(alice)['notify_reblogs']).to be true
      expect(settings(alice)['show_reblogs']).to be false
    end
  end

  describe 'export' do
    it 'writes every notify and notify_reblogs combination without dropping the other columns' do
      combinations = [
        { reblogs: true,  notify: false, notify_reblogs: false, languages: nil,       delivery: true },
        { reblogs: false, notify: true,  notify_reblogs: false, languages: ['en'],    delivery: false },
        { reblogs: true,  notify: false, notify_reblogs: true,  languages: ['ja'],    delivery: true },
        { reblogs: false, notify: true,  notify_reblogs: true,  languages: %w(en ja), delivery: false },
      ]
      targets = combinations.map do |options|
        target = Fabricate(:account)
        account.follow!(target, **options)
        [target, options]
      end

      rows = CSV.parse(Export.new(account).to_following_accounts_csv, headers: true)
      expect(rows.headers).to eq FollowImport::CsvFields.headers

      targets.each do |target, options|
        row = rows.find { |parsed| parsed['Account address'] == target.local_username_and_domain }
        expect(row['Show boosts']).to eq options[:reblogs].to_s
        expect(row['Notify on new posts']).to eq options[:notify].to_s
        expect(row['Notify on boosts']).to eq options[:notify_reblogs].to_s
        expect(row['Languages']).to eq(options[:languages]&.join(', '))
        expect(row['Delivery to home']).to eq options[:delivery].to_s
      end
    end
  end

  describe 'export and import round trip' do
    it 'restores notify_reblogs and the other follow settings' do
      account.follow!(alice, reblogs: false, notify: true, notify_reblogs: true, delivery: false, languages: %w(en ja))
      exported = Export.new(account).to_following_accounts_csv

      account.follow!(alice, reblogs: true, notify: false, notify_reblogs: false, delivery: true, languages: nil)
      ImportService.new.call(import_csv(exported))

      expect(settings(alice)).to eq(
        'show_reblogs' => false,
        'notify' => true,
        'notify_reblogs' => true,
        'languages' => %w(en ja),
        'delivery' => false
      )
    end
  end
end
# rubocop:enable Metrics/BlockLength
