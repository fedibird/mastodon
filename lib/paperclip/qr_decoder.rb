# frozen_string_literal: true

require 'mime/types/columnar'

module Paperclip
  class QrDecoder < Paperclip::Processor
    def make
      return @file if options[:style] != :original || !@attachment.instance.respond_to?(:description)

      code_word = decode_qrcode_from_file!
      @attachment.instance.description = [@attachment.instance.description, code_word].compact_blank.join('\n') if code_word.present?

      @file
    end

    private

    def decode_qrcode_from_file!
      begin
        command = Terrapin::CommandLine.new(Rails.configuration.x.qrtool_binary, 'decode :source')
        code_word = command.run(source: @file.path)&.gsub(/[[:^print:]]/) { '' }
      rescue Terrapin::ExitStatusError
        return nil
      rescue Terrapin::CommandNotFoundError
        log('Could not run the `qrtool` command. Please install qrtool.')
        return nil
      end

      code_word
    end
  end
end
