# frozen_string_literal: true

module GroupCreationIcons
  # Decides whether an S3 bucket itself refuses anonymous reads.
  # A private object ACL is not enough: a bucket policy can still allow
  # s3:GetObject for Principal "*". This does not look for a CloudFront
  # distribution in front of the bucket.
  module S3Access
    BLOCK_FLAGS = %w(block_public_acls ignore_public_acls block_public_policy restrict_public_buckets).freeze

    module_function

    def public_read_blocked?(block_configuration:, policy_json:, policy_status_public:)
      return false unless block_flags_on?(block_configuration)
      return false if policy_status_public
      return false if public_policy?(policy_json)

      true
    end

    def block_flags_on?(configuration)
      return false if configuration.nil?

      BLOCK_FLAGS.all? { |flag| truthy?(configuration, flag) }
    end

    def truthy?(configuration, flag)
      value = if configuration.respond_to?(flag)
                configuration.public_send(flag)
              elsif configuration.respond_to?(:[])
                configuration[flag] || configuration[flag.to_sym]
              end
      value == true
    end

    def public_policy?(policy_json)
      return false if policy_json.blank?

      document = JSON.parse(policy_json)
      statements = document.is_a?(Hash) ? document['Statement'] : nil
      statements = [statements] if statements.is_a?(Hash)
      return true unless statements.is_a?(Array)

      statements.any? { |statement| public_read_statement?(statement) }
    rescue JSON::ParserError, TypeError
      true
    end

    def public_read_statement?(statement)
      return false unless statement.is_a?(Hash)
      return false unless statement['Effect'].to_s.casecmp('Allow').zero?
      return false unless wildcard_principal?(statement['Principal'])

      actions = Array(statement['Action']).map { |action| action.to_s.downcase }
      actions.any? { |action| action == '*' || action == 's3:*' || action.end_with?(':getobject') || action.end_with?(':get*') }
    end

    def wildcard_principal?(principal)
      return true if principal == '*'
      return principal.any? { |item| wildcard_principal?(item) } if principal.is_a?(Array)
      return false unless principal.is_a?(Hash)

      aws = principal['AWS'] || principal[:AWS]
      aws == '*' || (aws.is_a?(Array) && aws.include?('*'))
    end
  end
end
