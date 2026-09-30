# frozen_string_literal: true

module Shaka
  # CLI targeting for a single report in a multi-reviewer batch.
  module LocalReviewRecordCommand
    private

    def record(parser)
      raise OptionParser::InvalidArgument, parser.to_s unless
        @arguments.empty? && @options[:ledger] && @options[:content_file]

      ledger = LocalReviewLedger.new(@options[:ledger])
      number = ledger.record!(record_content,
                              number: @options[:round])
      puts JSON.pretty_generate('ledger' => ledger.path, 'round' => number)
      0
    end

    def record_parser
      OptionParser.new do |flags|
        flags.banner = 'Usage: shaka review record --ledger PATH --content-file PATH [--round N]'
        flags.on('--round N') do |value|
          raise OptionParser::InvalidArgument, '--round must be a positive integer' unless value.match?(/\A[1-9]\d*\z/)

          @options[:round] = value.to_i
        end
        flags.on('--ledger PATH') { |value| @options[:ledger] = value }
        flags.on('--content-file PATH') { |value| @options[:content_file] = value }
        flags.on('-h', '--help') { @options[:help] = true }
      end
    end
  end
end
