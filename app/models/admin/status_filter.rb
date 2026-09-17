# frozen_string_literal: true

class Admin::StatusFilter
  KEYS = %i(
    media
    report_id
  ).freeze

  IGNORED_PARAMS = %w(page report_id).freeze

  attr_reader :params

  def initialize(account, params)
    @account = account
    @params  = params
  end

  def results
    scope = Status.include_expired.where(account: @account).where(visibility: [:public, :unlisted])

    params.each do |key, value|
      next if IGNORED_PARAMS.include?(key.to_s)

      scope.merge!(scope_for(key, value.to_s.strip)) if value.present?
    end

    scope
  end

  private

  def scope_for(key, _value)
    case key.to_s
    when 'media'
      Status.include_expired.joins(:media_attachments).merge(@account.media_attachments.reorder(nil)).group(:id).recent
    else
      raise "Unknown filter: #{key}"
    end
  end
end
