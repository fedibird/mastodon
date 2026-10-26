# frozen_string_literal: true

module EmojiReactionCapability
  # Write-time decision for one new emoji reaction. Returns the activity type
  # the legacy sender will enqueue ('EmojiReact', 'Like', or nil when nothing
  # is sent to the author's inbox). Raises before any insert when the policy
  # refuses the send. An existing row never reaches this gate.
  #
  # The node row is read once. The same snapshot is the digest, so the
  # decision and the token cannot observe two different nodes.
  module FallbackGate
    Context = Data.define(
      :reactor, :author, :status, :shortcode, :custom_emoji, :classification, :snapshot
    )

    module_function

    def enforce!(reactor:, status:, shortcode:, custom_emoji:, confirmation:)
      author = status.account
      classification, snapshot = classification_for(author, custom_emoji)
      return classification.activity_type if policy_free?(classification)

      policy = FallbackPolicy.read(reactor)
      raise Mastodon::EmojiReactionPolicyError.unknown_denied if policy.nil?
      return classification.activity_type if policy == 'allow'

      raise denial(classification) if policy == 'deny'
      raise Mastodon::EmojiReactionPolicyError.unknown_denied unless policy == 'ask'

      context = Context.new(
        reactor: reactor,
        author: author,
        status: status,
        shortcode: shortcode,
        custom_emoji: custom_emoji,
        classification: classification,
        snapshot: snapshot
      )
      accept_confirmation!(context, confirmation)
      classification.activity_type
    end

    def policy_free?(classification)
      classification.mechanism == :native || classification.mechanism == :not_delivered
    end

    def denial(classification)
      return Mastodon::EmojiReactionPolicyError.fallback_denied if classification.mechanism == :like_fallback

      Mastodon::EmojiReactionPolicyError.unknown_denied
    end

    def classification_for(author, custom_emoji)
      kind = custom_emoji.present? ? :custom : :unicode
      if author.local? || author.silenced? || !author.activitypub?
        snapshot = NodeSnapshot.absent
        return [ActualDelivery.classify(author, kind, nil, snapshot), snapshot]
      end

      row, snapshot = NodeSnapshotLoader.load_record(author.domain)
      [ActualDelivery.classify(author, kind, row, snapshot), snapshot]
    end

    def accept_confirmation!(context, confirmation)
      expected = binding_for(context)
      payload = FallbackConfirmation.read(confirmation)
      return if payload && match?(payload, expected) && FallbackConfirmation.consume!(payload['jti']) == :ok

      raise confirmation_error(confirmation, expected)
    end

    def confirmation_error(confirmation, expected)
      details = token_details(expected)
      if confirmation.is_a?(String) && confirmation.present?
        Mastodon::EmojiReactionPolicyError.confirmation_invalid(details)
      else
        Mastodon::EmojiReactionPolicyError.confirmation_required(details, message: confirmation_message(expected['activity_type']))
      end
    end

    # A Like is described as a favourite. An unknown case that still sends
    # EmojiReact must not use that sentence.
    def confirmation_message(activity_type)
      if activity_type == 'Like'
        Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED
      else
        Mastodon::EmojiReactionPolicyError::CONFIRM_REQUIRED_UNKNOWN
      end
    end

    def token_details(expected)
      {
        'mechanism' => expected['mechanism'],
        'effects' => expected['effects'],
        'confirmation_token' => FallbackConfirmation.issue(issue_payload(expected)),
        'expires_in' => FallbackConfirmation.expires_in,
      }
    end

    def binding_for(context)
      classification = context.classification
      {
        'v' => 1,
        'user_id' => context.reactor.user.id,
        'status_id' => context.status.id,
        'emoji' => emoji_identity(context.shortcode, context.custom_emoji),
        'domain' => context.author.domain.to_s,
        'mechanism' => classification.mechanism.to_s,
        'activity_type' => classification.activity_type,
        'effects' => classification.effects,
        'state_digest' => ActualDelivery.state_digest(classification, context.snapshot, 'ask'),
        'policy' => 'ask',
      }
    end

    def issue_payload(expected)
      expected.merge('jti' => SecureRandom.uuid)
    end

    def emoji_identity(shortcode, custom_emoji)
      if custom_emoji
        { 'kind' => 'custom', 'custom_emoji_id' => custom_emoji.id }
      else
        { 'kind' => 'unicode', 'name' => shortcode.to_s }
      end
    end

    def match?(payload, expected)
      payload['v'] == 1 &&
        payload['user_id'] == expected['user_id'] &&
        payload['status_id'] == expected['status_id'] &&
        payload['emoji'] == expected['emoji'] &&
        payload['domain'].to_s == expected['domain'] &&
        payload['mechanism'] == expected['mechanism'] &&
        payload['activity_type'] == expected['activity_type'] &&
        payload['effects'] == expected['effects'] &&
        payload['policy'] == 'ask' &&
        digest_match?(payload['state_digest'], expected['state_digest']) &&
        payload['jti'].is_a?(String) && payload['jti'].match?(FallbackConfirmation::JTI_FORMAT)
    end

    def digest_match?(left, right)
      return false unless left.is_a?(String) && right.is_a?(String)
      return false unless left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
