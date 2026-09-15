# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LegacyCleanup do
  let(:account) { Fabricate(:account, username: 'importer') }
  let(:before)  { Time.zone.parse('2026-09-01T00:00:00Z') }

  def create_follow_import(created_at:, pipeline_version: nil, overwrite: false)
    import = Import.create!(
      account: account,
      type: 'following',
      overwrite: overwrite,
      data: attachment_fixture('new-following-imports.txt'),
      follow_import_pipeline_version: pipeline_version
    )
    import.update_column(:created_at, created_at)
    import
  end

  it 'requires a BEFORE cutoff' do
    expect { described_class.new(before: nil) }.to raise_error(ArgumentError, /BEFORE is required/)
  end

  it 'lists unmarked follow imports older than BEFORE and does not delete them on dry-run' do
    target = create_follow_import(created_at: before - 1.day, overwrite: true)

    result = described_class.new(before: before).call

    expect(result.apply).to be false
    expect(result.candidates.map(&:id)).to eq [target.id]
    expect(Import.exists?(target.id)).to be true
  end

  it 'excludes a follow import that is referenced by a FollowImportBatch' do
    import = create_follow_import(created_at: before - 1.day)
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(account), import_id: import.id,
                              imported_at: Time.now.utc, mode: :merge, target_count: 0,
                              resolved_target_count: 0, unresolved_target_count: 0)

    result = described_class.new(before: before).call

    expect(result.candidates).to be_empty
    expect(Import.exists?(import.id)).to be true
  end

  it 'excludes a marked recovery-aware follow import' do
    import = create_follow_import(created_at: before - 1.day, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)

    result = described_class.new(before: before).call

    expect(result.candidates).to be_empty
    expect(Import.exists?(import.id)).to be true
  end

  it 'excludes an unknown non-NULL pipeline version' do
    v2   = create_follow_import(created_at: before - 1.day, pipeline_version: 2)
    v999 = create_follow_import(created_at: before - 1.week, pipeline_version: 999)

    result = described_class.new(before: before, apply: true).call

    expect(result.candidates).to be_empty
    expect(result.destroyed_ids).to be_empty
    expect(Import.exists?(v2.id)).to be true
    expect(Import.exists?(v999.id)).to be true
  end

  it 'excludes a non-follow import' do
    blocking = Import.create!(account: account, type: 'blocking', data: attachment_fixture('imports.txt'))
    blocking.update_column(:created_at, before - 1.day)

    result = described_class.new(before: before).call

    expect(result.candidates).to be_empty
    expect(Import.exists?(blocking.id)).to be true
  end

  it 'excludes an unmarked follow import created at or after BEFORE' do
    import = create_follow_import(created_at: before)

    result = described_class.new(before: before).call

    expect(result.candidates).to be_empty
    expect(Import.exists?(import.id)).to be true
  end

  it 'writes a manifest CSV when asked and still does not delete on dry-run' do
    import = create_follow_import(created_at: before - 2.days, overwrite: true)
    path   = Rails.root.join('tmp', "legacy-follow-imports-#{SecureRandom.hex(8)}.csv")

    result = described_class.new(before: before, manifest_path: path.to_s).call

    expect(result.manifest_path).to eq path.to_s
    expect(Import.exists?(import.id)).to be true
    rows = CSV.read(path, headers: true)
    expect(rows.size).to eq 1
    expect(rows.first['import_id']).to eq import.id.to_s
    expect(rows.first['account_id']).to eq account.id.to_s
    expect(rows.first['username']).to eq 'importer'
    expect(rows.first['overwrite']).to eq 'true'
  ensure
    FileUtils.rm_f(path)
  end

  it 'destroys only the matching unmarked leftovers when apply is set' do
    doomed   = create_follow_import(created_at: before - 1.week)
    too_new  = create_follow_import(created_at: before + 1.hour)
    marked   = create_follow_import(created_at: before - 1.week, pipeline_version: Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    blocking = Import.create!(account: account, type: 'blocking', data: attachment_fixture('imports.txt'))
    blocking.update_column(:created_at, before - 1.week)

    result = described_class.new(before: before, apply: true).call

    expect(result.apply).to be true
    expect(result.destroyed_ids).to eq [doomed.id]
    expect(Import.exists?(doomed.id)).to be false
    expect(Import.exists?(too_new.id)).to be true
    expect(Import.exists?(marked.id)).to be true
    expect(Import.exists?(blocking.id)).to be true
  end

  it 're-checks NULL marker and missing batch immediately before destroy' do
    doomed  = create_follow_import(created_at: before - 1.week)
    raced   = create_follow_import(created_at: before - 1.week)
    batched = create_follow_import(created_at: before - 1.week)

    cleanup = described_class.new(before: before, apply: true)
    expect(cleanup.candidates.map(&:id)).to contain_exactly(doomed.id, raced.id, batched.id)

    raced.update_column(:follow_import_pipeline_version, Import::CURRENT_FOLLOW_IMPORT_PIPELINE_VERSION)
    FollowImportBatch.create!(subject: ModerationSubject.for_account!(account), import_id: batched.id,
                              imported_at: Time.now.utc, mode: :merge, target_count: 0,
                              resolved_target_count: 0, unresolved_target_count: 0)

    result = cleanup.call

    expect(result.destroyed_ids).to eq [doomed.id]
    expect(result.skipped_ids).to contain_exactly(raced.id, batched.id)
    expect(Import.exists?(doomed.id)).to be false
    expect(Import.exists?(raced.id)).to be true
    expect(Import.exists?(batched.id)).to be true
  end
end
