# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require_relative "errors"

module Devdash
  module Transports
    class HttpJson
      Response = Data.define(:status, :headers, :body)
      RETRYABLE_STATUSES = [429, 502, 503, 504].freeze

      def initialize(base_uri:, default_headers: {}, open_timeout: 10, read_timeout: 30, max_retries: 3, sleeper: Kernel.method(:sleep))
        @base_uri = URI(base_uri)
        @default_headers = default_headers.transform_keys(&:to_s)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @sleeper = sleeper
      end

      def get(path:, query:, headers: {})
        request(:GET, path, query, headers)
      end

      def post(path:, query: {}, headers: {}, body: nil)
        request(:POST, path, query, headers, body)
      end

      private

      def request(method, path, query, headers, body = nil)
        attempts = 0
        loop do
          begin
          response = perform(method, path, query, headers, body)
          status = response.code.to_i
          if RETRYABLE_STATUSES.include?(status)
            retry_response(response, attempts)
            attempts += 1
            next
          elsif status == 401 || status == 403
            raise AuthenticationError, "HTTP authentication failed (status #{status})"
          elsif status < 200 || status >= 300
            raise ResponseError, "HTTP request failed (status #{status})"
          end

          parsed = JSON.parse(response.body)
          return Response.new(status, response.each_header.to_h, parsed)
          rescue JSON::ParserError => error
            raise ResponseError, "invalid JSON response: #{error.message.split(":").first}"
          rescue Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => error
            retry_or_raise(TransientError, "HTTP transport failed (#{error.class})", attempts)
            attempts += 1
          end
        end
      end

      def perform(method, path, query, headers, body)
        uri = @base_uri + path.to_s
        uri.query = URI.encode_www_form(query || {}) unless query.nil? || query.empty?
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        (@default_headers.merge(headers.transform_keys(&:to_s))).each { |key, value| request[key] = value }
        request.body = JSON.generate(body) unless body.nil?
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          http.request(request)
        end
      end

      def retry_response(response, attempts)
        retry_or_raise(response.code.to_i == 429 ? RateLimitError : TransientError,
          "HTTP request failed (status #{response.code})", attempts, response["retry-after"])
      end

      def retry_or_raise(error_class, message, attempts, retry_after = nil)
        return raise(error_class, message) if attempts >= @max_retries

        delay = retry_after ? Float(retry_after) : (2**attempts).to_f
        @sleeper.call(delay)
        true
      rescue ArgumentError
        @sleeper.call((2**attempts).to_f)
        true
      end
    end
  end
end
