# frozen_string_literal: true

class FeedInsertWorker
  include Sidekiq::Worker

  def perform(status_id, id, type = 'home', options = {})
    @type    = type.to_sym
    @status  = Status.find(status_id)
    @options = options.symbolize_keys
    # Off keeps the old arguments and does not parse evidence. A bad payload
    # parses to nil and the old check runs.
    @delivery = FeedDelivery.observe? ? FeedDelivery::Evidence.from_job_options(@options) : nil

    case @type
    when :home
      @follower = Account.find(id)
    when :list
      @list     = List.find(id)
      @follower = @list.account
    end

    check_and_insert
  rescue ActiveRecord::RecordNotFound
    true
  end

  private

  def check_and_insert
    if feed_filtered?
      perform_unpush if update?
    else
      perform_push
      perform_notify if notify?
    end
  end

  def feed_filtered?
    # Home deliveries without keyword evidence stay on the old filter. List
    # deliveries and keyword evidence need the in-process decision.
    if FeedDelivery.observe? && (@type == :list || @delivery)
      @decision = FeedManager.instance.assess(@type, @status, feed_target, delivery: @delivery)
      @decision.filtered?
    else
      @decision = nil
      legacy_feed_filtered?
    end
  end

  def legacy_feed_filtered?
    case @type
    when :home
      FeedManager.instance.filter?(:home, @status, @follower)
    when :list
      FeedManager.instance.filter?(:list, @status, @list)
    end
  end

  def feed_target
    @type == :list ? @list : @follower
  end

  def notify?
    return false if update? || @status.reblog? || (@status.reply? && @status.in_reply_to_account_id != @status.account_id)

    Follow.find_by(account: @follower, target_account: @status.account)&.notify?
  end

  def perform_push
    case @type
    when :home
      if update?
        FeedManager.instance.push_to_home(@follower, @status, update: true)
      else
        FeedManager.instance.push_to_home(@follower, @status)
      end
    when :list
      push_list
    end
  end

  def push_list
    if @decision && update?
      FeedManager.instance.push_to_list(@list, @status, update: true, decision: @decision)
    elsif @decision
      FeedManager.instance.push_to_list(@list, @status, decision: @decision)
    elsif update?
      FeedManager.instance.push_to_list(@list, @status, update: true)
    else
      FeedManager.instance.push_to_list(@list, @status)
    end
  end

  def perform_unpush
    case @type
    when :home
      FeedManager.instance.unpush_from_home(@follower, @status, update: true)
    when :list
      FeedManager.instance.unpush_from_list(@list, @status, update: true)
    end
  end

  def update?
    @options[:update]
  end

  def perform_notify
    NotifyService.new.call(@follower, :status, @status)
  end
end
