# frozen_string_literal: true

require_relative '../error'
require_relative 'evidence'
require_relative 'finding'

module Shaka
  # Records dispositions by stable round number without overwriting a concurrent peer.
  module LocalReviewRecording
    def record!(content, number: nil)
      raise Error, 'Record content must be an object.' unless content.is_a?(Hash)

      update do
        number = record_number(content, number)
        updated = rounds.dup
        updated[number - 1] = recorded_round(content, number)
        write(data.merge(content.slice('fallback'), 'rounds' => updated))
        number
      end
    end

    private

    def record_number(content, number)
      number ||= content['round'] || default_record_number
      return number if number.is_a?(Integer) && number.positive? && number <= rounds.size

      raise Error, '--round must name an existing positive round number.'
    end

    def recorded_round(content, number)
      existing = rounds.fetch(number - 1)
      raise Error, 'Record dispositions before progressing to another head.' unless existing['head'] == last_head

      check_target!(content, existing)
      round = existing.merge(content.slice('findings', 'model', 'tokens', 'cost', 'estimate'))
      check_findings!(round, number)
      round
    end

    def default_record_number
      raise Error, 'The ledger has no round to record.' if rounds.empty?
      raise Error, 'A multi-reviewer batch requires --round N to record the intended review.' if
        rounds.count { |round| round['head'] == last_head } > 1

      rounds.size
    end

    def check_target!(content, round)
      %w[head reviewer].each do |key|
        next unless content.key?(key)
        next if content[key] == round[key]

        raise Error, "Record #{key} does not match the selected round."
      end
    end

    # The count check keeps a finding from dropping out between the report and the comment.
    def check_findings!(round, number)
      findings = LocalReviewFinding.list(round['findings'], "round #{number} finding")
      reported = reported_count(round)
      return if findings.size == reported

      raise Error, "Round #{number}'s report counts #{reported} findings; #{findings.size} were recorded."
    end
  end
end
