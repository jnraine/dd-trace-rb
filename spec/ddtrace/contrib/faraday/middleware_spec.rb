require 'spec_helper'

require 'ddtrace'
require 'faraday'
require 'ddtrace/ext/distributed'

RSpec.describe 'Faraday middleware' do
  let(:tracer) { Datadog::Tracer.new(writer: FauxWriter.new) }

  let(:client) do
    ::Faraday.new('http://example.com') do |builder|
      builder.use(:ddtrace, middleware_options)
      builder.adapter(:test) do |stub|
        stub.get('/success') { |_| [200, {}, 'OK'] }
        stub.post('/failure') { |_| [500, {}, 'Boom!'] }
        stub.get('/not_found') { |_| [404, {}, 'Not Found.'] }
      end
    end
  end

  let(:middleware_options) { {} }
  let(:configuration_options) { { tracer: tracer } }

  let(:request_span) do
    tracer.writer.spans(:keep).find { |span| span.name == Datadog::Contrib::Faraday::NAME }
  end

  before(:each) do
    Datadog.configure do |c|
      c.use :faraday, configuration_options
    end

    # Have to manually update this because its still
    # using global pin instead of configuration.
    # Remove this when we remove the pin.
    Datadog::Pin.get_from(::Faraday).tracer = tracer
  end

  context 'when there is no interference' do
    subject!(:response) { client.get('/success') }

    it do
      expect(response).to be_a_kind_of(::Faraday::Response)
      expect(response.body).to eq('OK')
      expect(response.status).to eq(200)
    end
  end

  context 'when there is successful request' do
    subject!(:response) { client.get('/success') }

    it do
      expect(request_span).to_not be nil
      expect(request_span.service).to eq(Datadog::Contrib::Faraday::SERVICE)
      expect(request_span.name).to eq(Datadog::Contrib::Faraday::NAME)
      expect(request_span.resource).to eq('GET')
      expect(request_span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq('GET')
      expect(request_span.get_tag(Datadog::Ext::HTTP::STATUS_CODE)).to eq('200')
      expect(request_span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/success')
      expect(request_span.get_tag(Datadog::Ext::NET::TARGET_HOST)).to eq('example.com')
      expect(request_span.get_tag(Datadog::Ext::NET::TARGET_PORT)).to eq('80')
      expect(request_span.span_type).to eq(Datadog::Ext::HTTP::TYPE)
      expect(request_span.status).to_not eq(Datadog::Ext::Errors::STATUS)
    end
  end

  context 'when there is a failing request' do
    subject!(:response) { client.post('/failure') }

    it do
      expect(request_span.service).to eq(Datadog::Contrib::Faraday::SERVICE)
      expect(request_span.name).to eq(Datadog::Contrib::Faraday::NAME)
      expect(request_span.resource).to eq('POST')
      expect(request_span.get_tag(Datadog::Ext::HTTP::METHOD)).to eq('POST')
      expect(request_span.get_tag(Datadog::Ext::HTTP::URL)).to eq('/failure')
      expect(request_span.get_tag(Datadog::Ext::HTTP::STATUS_CODE)).to eq('500')
      expect(request_span.get_tag(Datadog::Ext::NET::TARGET_HOST)).to eq('example.com')
      expect(request_span.get_tag(Datadog::Ext::NET::TARGET_PORT)).to eq('80')
      expect(request_span.span_type).to eq(Datadog::Ext::HTTP::TYPE)
      expect(request_span.status).to eq(Datadog::Ext::Errors::STATUS)
      expect(request_span.get_tag(Datadog::Ext::Errors::TYPE)).to eq('Error 500')
      expect(request_span.get_tag(Datadog::Ext::Errors::MSG)).to eq('Boom!')
    end
  end

  context 'when there is a client error' do
    subject!(:response) { client.get('/not_found') }

    it { expect(request_span.status).to_not eq(Datadog::Ext::Errors::STATUS) }
  end

  context 'when there is custom error handling' do
    subject!(:response) { client.get('not_found') }

    let(:middleware_options) { { error_handler: custom_handler } }
    let(:custom_handler) { ->(env) { (400...600).cover?(env[:status]) } }
    it { expect(request_span.status).to eq(Datadog::Ext::Errors::STATUS) }
  end

  context 'when split by domain' do
    subject!(:response) { client.get('/success') }

    let(:middleware_options) { { split_by_domain: true } }

    it do
      expect(request_span.name).to eq(Datadog::Contrib::Faraday::NAME)
      expect(request_span.service).to eq('example.com')
      expect(request_span.resource).to eq('GET')
    end
  end

  context 'default request headers' do
    subject(:response) { client.get('/success') }

    let(:headers) { response.env.request_headers }

    it do
      expect(headers).to_not include(Datadog::Ext::DistributedTracing::HTTP_HEADER_TRACE_ID)
      expect(headers).to_not include(Datadog::Ext::DistributedTracing::HTTP_HEADER_PARENT_ID)
    end
  end

  context 'when distributed tracing is enabled' do
    subject(:response) { client.get('/success') }

    let(:middleware_options) { { distributed_tracing: true } }
    let(:headers) { response.env.request_headers }

    it do
      expect(headers[Datadog::Ext::DistributedTracing::HTTP_HEADER_TRACE_ID]).to eq(request_span.trace_id.to_s)
      expect(headers[Datadog::Ext::DistributedTracing::HTTP_HEADER_PARENT_ID]).to eq(request_span.span_id.to_s)
    end

    context 'but the tracer is disabled' do
      before(:each) { tracer.enabled = false }
      it do
        expect(headers).to_not include(Datadog::Ext::DistributedTracing::HTTP_HEADER_TRACE_ID)
        expect(headers).to_not include(Datadog::Ext::DistributedTracing::HTTP_HEADER_PARENT_ID)
        expect(request_span).to be nil
      end
    end
  end

  context 'global service name' do
    let(:service_name) { 'faraday-global' }

    before(:each) do
      @old_service_name = Datadog.configuration[:faraday][:service_name]
      Datadog.configure { |c| c.use :faraday, service_name: service_name }
    end

    after(:each) { Datadog.configure { |c| c.use :faraday, service_name: @old_service_name } }

    it do
      client.get('/success')
      expect(request_span.service).to eq(service_name)
    end
  end

  context 'service name per request' do
    subject!(:response) { client.get('/success') }

    let(:middleware_options) { { service_name: service_name } }
    let(:service_name) { 'adhoc-request' }

    it do
      expect(request_span.service).to eq(service_name)
    end
  end
end
