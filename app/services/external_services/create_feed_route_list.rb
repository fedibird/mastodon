# frozen_string_literal: true

module ExternalServices
  # Creates a list for a destination picker. Lists, their limit, and their
  # names belong to the Account, so creations serialize on the account row;
  # a lock on the User would let two Users of one Account both count 49
  # lists. The row is locked FOR NO KEY UPDATE so unrelated writes that only
  # reference the account keep working. List writes that do not come through
  # here (the REST API, for example) are not serialized by this lock.
  class CreateFeedRouteList
    TITLE_LIMIT = 128

    Result = Struct.new(:list, :error)

    def call(user:, title:)
      title = title.to_s.squish
      return Result.new(nil, :blank) if title.empty?
      return Result.new(nil, :too_long) if title.length > TITLE_LIMIT

      List.transaction do
        Account.where(id: user.account_id).lock('FOR NO KEY UPDATE').pick(:id)
        build(user.account_id, title)
      end
    end

    private

    def build(account_id, title)
      scope = List.where(account_id: account_id)
      return Result.new(nil, :limit) if scope.count >= List::PER_ACCOUNT_LIMIT
      return Result.new(nil, :duplicate) if scope.exists?(['LOWER(title) = ?', title.downcase])

      list = List.new(account_id: account_id, title: title)
      return Result.new(list, nil) if list.save

      Result.new(nil, list.errors[:base].any? ? :limit : :failed)
    end
  end
end
