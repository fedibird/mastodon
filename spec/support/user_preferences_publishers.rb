# frozen_string_literal: true

class RecordingPublisher
  def initialize(redis, messages, returns, observer)
    @redis = redis
    @messages = messages
    @returns = returns
    @observer = observer
  end

  def publish(channel, message)
    @observer&.call
    @messages << [channel, message]
    @returns << @redis.publish(channel, message)
  end

  def method_missing(name, *args, &block)
    return @redis.public_send(name, *args, &block) if @redis.respond_to?(name)

    super
  end

  def respond_to_missing?(name, include_private = false)
    @redis.respond_to?(name, include_private) || super
  end
end

class RaisingPublisher
  def initialize(redis, messages)
    @redis = redis
    @messages = messages
  end

  def publish(channel, message)
    @messages << [channel, message]
    raise Redis::CannotConnectError, 'down' if channel.start_with?('timeline:preferences:')

    @redis.publish(channel, message)
  end

  def method_missing(name, *args, &block)
    return @redis.public_send(name, *args, &block) if @redis.respond_to?(name)

    super
  end

  def respond_to_missing?(name, include_private = false)
    @redis.respond_to?(name, include_private) || super
  end
end

class ZeroPublisher
  def initialize(messages, returns)
    @messages = messages
    @returns = returns
  end

  def publish(channel, message)
    @messages << [channel, message]
    @returns << 0
    0
  end
end
