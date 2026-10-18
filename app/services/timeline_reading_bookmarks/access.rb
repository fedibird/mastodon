# frozen_string_literal: true

module TimelineReadingBookmarks
  # Write-time membership. A list must belong to the signed-in account.
  # A group must be a local group that is not blocking or suspended.
  # Missing and foreign lists share one 404 so the response has no title.
  class Access
    def self.ensure!(account, source, context)
      new(account, source, context).ensure!
    end

    def initialize(account, source, context)
      @account = account
      @source = source
      @context = Contract.stringify(context || {})
    end

    def ensure!
      case @source
      when 'home', 'limited', 'personal'
        raise Reject, 'missing_account' if @account.nil?
      when 'list'
        ensure_list!
      when 'group'
        ensure_group!
      when 'hashtag', 'public', 'domain'
        nil
      else
        raise Reject, 'invalid_source'
      end
    end

    private

    def ensure_list!
      raise Reject, 'missing_account' if @account.nil?

      id = @context['id']
      return if List.where(account_id: @account.id, id: id).exists?

      raise Reject.new('source_not_found', 404)
    end

    def ensure_group!
      raise Reject, 'missing_account' if @account.nil?

      group = Account.groups.find_by(id: @context['id'])
      raise Reject.new('source_not_found', 404) if group.nil?
      raise Reject, 'remote_group' if group.domain.present?
      raise Reject, 'not_accessible' if group.suspended? || group.blocking?(@account)
    end
  end
end
