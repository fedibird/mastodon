# frozen_string_literal: true

class PostingContext::RevalidationRegistry
  include Redisable

  # One in-flight job per group. The lock lease is longer than the cooldown
  # so a crashed worker stops looking active, and a later request can replace
  # it. Completed state stays readable after the lock is released.
  COOLDOWN = 5.minutes
  LEASE = 10.minutes
  STATE_TTL = 30.minutes
  ADMIN_LIMIT = 30
  ADMIN_WINDOW = 10.minutes
  HOST_LIMIT = 12
  HOST_WINDOW = 10.minutes

  PREFIX = 'posting_context:revalidation:v1'

  Outcome = Struct.new(:status, :payload, :retry_after, keyword_init: true)

  # State changes require the caller to still own the lock. Lua runs
  # atomically, so a lock acquired by another request cannot be extended
  # or deleted here.
  COMPARE_AND_SET = <<~LUA
    local current = redis.call('GET', KEYS[1])
    if not current then
      return 0
    end
    local request_id = string.match(current, '"request_id"%s*:%s*"([^"]+)"')
    if request_id ~= ARGV[1] then
      return 0
    end
    local queued = string.find(current, '"state":"queued"', 1, true)
    local running = string.find(current, '"state":"running"', 1, true)
    if not queued and not running then
      return 0
    end
    if ARGV[4] == 'running' and not queued then
      return 0
    end
    local lock = redis.call('GET', KEYS[2])
    if lock ~= ARGV[1] then
      return 0
    end
    redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
    if ARGV[5] == 'release' then
      if redis.call('GET', KEYS[2]) == ARGV[1] then
        redis.call('DEL', KEYS[2])
      end
    else
      redis.call('EXPIRE', KEYS[2], tonumber(ARGV[6]))
    end
    return 1
  LUA

  # Used only when the lease is already gone. A lock owned by another
  # request is left untouched, including its key.
  RECOVER_EXPIRED = <<~LUA
    local current = redis.call('GET', KEYS[1])
    if not current then
      return 0
    end
    local request_id = string.match(current, '"request_id"%s*:%s*"([^"]+)"')
    if request_id ~= ARGV[1] then
      return 0
    end
    local queued = string.find(current, '"state":"queued"', 1, true)
    local running = string.find(current, '"state":"running"', 1, true)
    if not queued and not running then
      return 0
    end
    local lock = redis.call('GET', KEYS[2])
    if lock then
      return 0
    end
    redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
    return 1
  LUA

  EXTEND_LEASE = <<~LUA
    if redis.call('GET', KEYS[1]) ~= ARGV[1] then
      return 0
    end
    redis.call('EXPIRE', KEYS[1], tonumber(ARGV[2]))
    return 1
  LUA

  # Publishing a request id, its lock, its queued state, and the cooldown is
  # one Redis operation. A lock that already exists is left unchanged, and
  # its value is returned so the caller can ignore an older state document.
  CREATE_REQUEST = <<~LUA
    local existing = redis.call('GET', KEYS[1])
    if existing then
      return {0, existing}
    end
    redis.call('SET', KEYS[1], ARGV[1], 'EX', tonumber(ARGV[3]))
    redis.call('SET', KEYS[2], ARGV[2], 'EX', tonumber(ARGV[4]))
    redis.call('SET', KEYS[3], ARGV[1], 'EX', tonumber(ARGV[5]))
    return {1, ARGV[1]}
  LUA

  def request!(account, requester:)
    recover_expired!(account.id)
    current = load_state(account.id)

    if inflight?(account.id, current)
      return Outcome.new(status: :inflight, payload: payload_for(current))
    end

    cooldown = retry_after(cooldown_key(account.id))
    if cooldown
      return Outcome.new(status: :cooldown, retry_after: cooldown, payload: payload_for(current))
    end

    limited = rate_limit!(requester, account)
    if limited
      return Outcome.new(status: :limited, retry_after: limited)
    end

    create_request!(account)
  end

  def read(account)
    recover_expired!(account.id)
    state = load_state(account.id)
    return { state: 'idle', account_id: account.id.to_s } if state.nil?

    payload_for(state)
  end

  def mark_running!(account_id, request_id)
    state = load_state(account_id)
    return false if state.nil? || state['request_id'] != request_id

    compare_and_set!(account_id, request_id, state.merge(
                                               'state' => 'running',
                                               'started_at' => state['started_at'].presence || iso_now
                                             ), transition: 'running')
  end

  def renew!(account_id, request_id)
    state = load_state(account_id)
    return false if state.nil? || state['request_id'] != request_id || state['state'] != 'running'

    compare_and_set!(account_id, request_id, state, transition: 'renew')
  end

  # Heartbeat used while actor and affiliation fetches are in progress.
  # Extends the lease only when this request still owns the lock.
  def extend_lease!(account_id, request_id)
    RedisConfiguration.with do |connection|
      connection.eval(
        EXTEND_LEASE,
        keys: [lock_key(account_id)],
        argv: [request_id, LEASE.to_i]
      ).to_i == 1
    end
  end

  def owns_lock?(account_id, request_id)
    return false if request_id.blank?

    redis.get(lock_key(account_id)) == request_id
  end

  def finish!(account_id, request_id, result)
    state = load_state(account_id)
    return false if state.nil? || state['request_id'] != request_id

    compare_and_set!(account_id, request_id, state.merge(
                                               'state' => result.state,
                                               'actor' => result.actor,
                                               'affiliations' => result.affiliations,
                                               'finished_at' => iso_now
                                             ), transition: 'release')
  end

  private

  def create_request!(account)
    request_id = SecureRandom.uuid
    state = queued_state(account, request_id)
    created, lock_owner = accept_request(account.id, request_id, state)
    return Outcome.new(status: :created, payload: payload_for(state)) if created

    Outcome.new(status: :inflight, payload: inflight_payload(account, lock_owner))
  end

  def queued_state(account, request_id)
    {
      'state' => 'queued',
      'request_id' => request_id,
      'account_id' => account.id.to_s,
      'requested_at' => iso_now,
      'started_at' => nil,
      'finished_at' => nil,
      'actor' => nil,
      'affiliations' => nil,
    }
  end

  def accept_request(account_id, request_id, state)
    result = redis.eval(
      CREATE_REQUEST,
      keys: [lock_key(account_id), state_key(account_id), cooldown_key(account_id)],
      argv: [request_id, JSON.generate(state), LEASE.to_i, STATE_TTL.to_i, COOLDOWN.to_i]
    )
    [result[0].to_i == 1, result[1]]
  end

  # A held lock whose queued state is not stored yet must not be reported as
  # an older completed request.
  def inflight_payload(account, lock_owner)
    current = load_state(account.id)
    if current && current['request_id'] == lock_owner && active_state?(current)
      payload_for(current)
    else
      { state: 'queued', account_id: account.id.to_s }
    end
  end

  def rate_limit!(requester, account)
    admin_retry = increment_limit(admin_key(requester.id), ADMIN_LIMIT, ADMIN_WINDOW)
    return admin_retry if admin_retry

    increment_limit(host_key(account.domain), HOST_LIMIT, HOST_WINDOW)
  end

  def increment_limit(key, limit, window)
    count = redis.incr(key)
    redis.expire(key, window.to_i) if count == 1
    return unless count > limit

    retry_after(key) || 1
  end

  def recover_expired!(account_id)
    state = load_state(account_id)
    return unless state && active_state?(state)

    failed = state.merge(
      'state' => 'failed',
      'actor' => 'failed',
      'affiliations' => 'failed',
      'finished_at' => iso_now
    )
    redis.eval(
      RECOVER_EXPIRED,
      keys: [state_key(account_id), lock_key(account_id)],
      argv: [state['request_id'], JSON.generate(failed), STATE_TTL.to_i]
    )
  end

  def inflight?(account_id, state)
    state && active_state?(state) && redis.get(lock_key(account_id)) == state['request_id']
  end

  def active_state?(state)
    %w(queued running).include?(state['state'])
  end

  def compare_and_set!(account_id, request_id, state, transition:)
    redis.eval(
      COMPARE_AND_SET,
      keys: [state_key(account_id), lock_key(account_id)],
      argv: [request_id, JSON.generate(state), STATE_TTL.to_i, transition, transition == 'release' ? 'release' : 'keep', LEASE.to_i]
    ).to_i == 1
  end

  def load_state(account_id)
    raw = redis.get(state_key(account_id))
    return if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def payload_for(state)
    return { state: 'idle' } if state.nil?

    body = {
      state: state['state'],
      account_id: state['account_id'],
    }
    %w(request_id requested_at started_at finished_at actor affiliations).each do |key|
      body[key.to_sym] = state[key] if state[key].present?
    end
    body
  end

  def retry_after(key)
    ttl = redis.ttl(key)
    ttl.positive? ? ttl : nil
  end

  def iso_now
    Time.now.utc.iso8601
  end

  def state_key(account_id)
    "#{PREFIX}:#{account_id}"
  end

  def lock_key(account_id)
    "#{PREFIX}:#{account_id}:lock"
  end

  def cooldown_key(account_id)
    "#{PREFIX}:#{account_id}:cooldown"
  end

  def admin_key(user_id)
    "#{PREFIX}:admin:#{user_id}"
  end

  def host_key(domain)
    "#{PREFIX}:host:#{domain}"
  end
end
