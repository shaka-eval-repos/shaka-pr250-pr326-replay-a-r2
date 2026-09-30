# frozen_string_literal: true

require 'json'
require_relative '../error'
require_relative 'evidence'
require_relative 'finding'
require_relative 'recording'

module Shaka
  # Private record of a local review loop: each round's commit, reviewer settings, report, and
  # what became of its findings. It stays outside the checkout until `review publish` renders it,
  # and it has the same shape as that command's content file.
  class LocalReviewLedger
    include LocalReviewRecording

    attr_reader :path

    # Only `review run` can start a ledger, so only it needs the checkout to keep the ledger out of.
    def initialize(path, root: nil)
      @path = File.expand_path(path)
      directory = File.realpath(File.dirname(@path))
      raise Error, '--ledger must be outside the candidate checkout' if
        root && (directory == root || directory.start_with?("#{root}/"))
    end

    def rounds = data.fetch('rounds')

    def last_head = rounds.last&.fetch('head')

    # Current-head peers never enter the history or the prompt seen by another reviewer.
    def previous_batch(head)
      earlier = rounds.reject { |round| round['head'] == head }
      earlier.select { |round| round['head'] == earlier.last&.fetch('head') }
    end

    def check_next!(base:, head:, reviewer:)
      return if rounds.empty?

      raise Error, "The ledger's rounds measure the change against #{data['base']}; use a new ledger." unless
        data['base'] == base

      check_new_review!(head, reviewer)
      return if head == last_head

      rounds.each_with_index do |round, index|
        next if recorded?(round)

        raise Error, "Record round #{index + 1}'s findings with `shaka review record` before the next round."
      end
    end

    # Finding ids belong to their reviewer, so one peer cannot erase another peer's evidence.
    def prior_findings(head:)
      rounds.reject { |round| round['head'] == head }.each_with_index.with_object({}) do |(round, index), latest|
        LocalReviewFinding.list(round['findings'], "round #{index + 1} finding").each do |finding|
          latest[[round['reviewer'].downcase, finding.id]] = finding
        end
      end.values
    end

    # Re-read under a stable sidecar lock: renaming the ledger cannot invalidate the lock.
    # A late peer can append only while its head is still the latest batch.
    def append!(base:, round:)
      snapshot = review_keys(rounds)
      update do
        check_snapshot!(snapshot)

        check_next!(base:, head: round.fetch('head'), reviewer: round.fetch('reviewer'))
        yield if block_given?
        write(data.merge('base' => base, 'rounds' => rounds + [round]))
        rounds.size
      end
    end

    private

    def data
      @data ||= if File.exist?(@path)
                  parsed = JSON.parse(File.read(@path, encoding: 'UTF-8'))
                  raise Error, "#{@path} is not a review ledger." unless
                    parsed.is_a?(Hash) && parsed['rounds'].is_a?(Array)

                  parsed
                else
                  { 'rounds' => [] }
                end
    end

    def check_new_review!(head, reviewer)
      reviewed = rounds.index do |round|
        round['head'] == head && (head != last_head || round['reviewer'].casecmp?(reviewer))
      end
      raise Error, "Round #{reviewed + 1} already reviewed #{head}; commit the fix first." if reviewed
    end

    def review_keys(items) = items.map { |entry| entry.values_at('head', 'reviewer', 'report') }

    def check_snapshot!(snapshot)
      return if review_keys(rounds.first(snapshot.size)) == snapshot

      raise Error, 'The review ledger changed or was replaced while the reviewer ran.'
    end

    def update
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        @data = nil
        yield
      end
    end

    def recorded?(round) = round.key?('findings') || reported_count(round).zero?

    def reported_count(round)
      match = File.read(round.fetch('report'), encoding: 'UTF-8').match(LocalReviewEvidence::CLOSING)
      raise Error, "Round report #{round['report']} has no FINDINGS count." unless match

      match[2].to_i
    end

    def write(content)
      temporary = "#{@path}.#{Process.pid}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(content)}\n", perm: 0o600)
      File.rename(temporary, @path)
      @data = content
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end
  end
end
