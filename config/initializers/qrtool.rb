# frozen_string_literal: true

Rails.application.configure do
  config.x.qrtool_binary = ENV['QRTOOL_BINARY'] || 'qrtool'
end
