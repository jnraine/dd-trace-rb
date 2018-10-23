module MetricHelpers
  # RSpec matcher for generic Statsd metric
  class SendStat < RSpec::Mocks::Matchers::HaveReceived
    def initialize(method_name, *args, &block)
      super(method_name, &block)
      @args = args
    end

    def name
      'send_stat'
    end

    def matches?(subject, &block)
      @constraints << with_constraint
      super
    end

    def does_not_match?(subject, &block)
      @constraints << with_constraint
      super
    end

    def with(*args)
      with_constraint.concat(args)
      self
    end

    protected

    def with_constraint
      @with_constraint ||= [
        'with',
        *@args
      ]
    end

    def merge_with_defaults(options)
      if options.nil?
        # Set default options
        Datadog::Metrics::DEFAULT_OPTIONS.dup
      else
        # Add tags to options
        options.dup.tap do |opts|
          opts[:tags] = if opts.key?(:tags)
                          opts[:tags].dup.concat(Datadog::Metrics::DEFAULT_TAGS)
                        else
                          Datadog::Metrics::DEFAULT_TAGS.dup
                        end
        end
      end
    end
  end

  # RSpec matcher for Statsd#increment
  class IncrementStat < SendStat
    def initialize(stat, &block)
      super(:increment, &block)
      @stat = stat
    end

    def name
      'increment_stat'
    end

    def with(*args)
      with_constraint[2] = merge_with_defaults(args.first)
      self
    end

    protected

    def with_constraint
      @with_constraint ||= [
        'with',
        @stat,
        Datadog::Metrics::DEFAULT_OPTIONS
      ]
    end
  end

  # RSpec matcher for Statsd#time
  class TimeStat < SendStat
    def initialize(stat, &block)
      super(:time, &block)
      @stat = stat
    end

    def name
      'time_stat'
    end

    def with(*args)
      with_constraint[2] = merge_with_defaults(args.first)
      self
    end

    protected

    def with_constraint
      @with_constraint ||= [
        'with',
        @stat,
        Datadog::Metrics::DEFAULT_OPTIONS
      ]
    end
  end

  def send_stat(*args)
    SendStat.new(*args)
  end

  def increment_stat(*args)
    IncrementStat.new(*args)
  end

  def time_stat(*args)
    TimeStat.new(*args)
  end

  shared_context 'metrics' do
    let(:statsd) { spy('statsd') } # TODO: Make this an instance double.
    let(:stats) { Hash.new(0) }
    let(:stats_mutex) { Mutex.new }

    before(:each) do
      allow(statsd).to receive(:increment) do |name, options = {}|
        stats_mutex.synchronize do
          stats[name] = 0 unless stats.key?(name)
          stats[name] += options.key?(:by) ? options[:by] : 1
        end
      end

      allow(statsd).to receive(:time) do |name, _options = {}, &block|
        stats_mutex.synchronize do
          stats[name] = 0 unless stats.key?(name)
          stats[name] += 1
        end
        block.call
      end
    end

    shared_examples_for 'an operation that increments stat' do |stat, options = {}|
      let(:transport) { super().tap { |t| t.statsd = statsd } }

      it do
        subject
        expect(statsd).to increment_stat(stat).with(options)
      end
    end
  end

  shared_context 'transport metrics' do
    include_context 'metrics'

    def transport_options(options = {}, encoder = Datadog::Encoding::MsgpackEncoder)
      options.merge(tags: transport_tags(options[:tags], encoder))
    end

    def transport_tags(tags = [], encoder = Datadog::Encoding::MsgpackEncoder)
      ["#{Datadog::HTTPTransport::TAG_ENCODING_TYPE}:#{encoder.content_type}"].tap do |default_tags|
        default_tags.concat(tags) unless tags.nil?
      end
    end

    shared_examples_for 'a transport operation that increments stat' do |stat, options = {}|
      let(:encoder) { Datadog::Encoding::MsgpackEncoder }
      let(:transport) { super().tap { |t| t.statsd = statsd } }

      it do
        subject
        expect(statsd).to increment_stat(stat).with(transport_options(options, encoder))
      end
    end

    shared_examples_for 'a transport operation that times stat' do |stat, options = {}|
      let(:encoder) { Datadog::Encoding::MsgpackEncoder.new }
      let(:transport) { super().tap { |t| t.statsd = statsd } }

      it do
        subject
        expect(statsd).to time_stat(stat).with(transport_options(options, encoder))
      end
    end
  end
end
