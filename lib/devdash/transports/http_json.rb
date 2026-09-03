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
      MAX_RETRY_AFTER = 300.0

      def initialize(base_uri:, default_headers: {}, open_timeout: 10, read_timeout: 30, max_retries: 3, sleeper: Kernel.method(:sleep), graphql_path: "/graphql")
        @base_uri = URI(base_uri)
        raise ResponseError, "HTTP base URI must include a scheme and host" unless @base_uri.scheme && @base_uri.host

        @default_headers = default_headers.transform_keys(&:to_s)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_retries = max_retries
        @sleeper = sleeper
        @graphql_path = normalize_graphql_path(graphql_path)
      end

      def get(path:, query:, headers: {})
        request(:GET, path, query, headers)
      end

      def post(path:, query: {}, headers: {}, body: nil)
        request(:POST, path, query, headers, body)
      end

      private

      def request(method, path, query, headers, body = nil)
        validate_post!(path, body) if method == :POST
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
        uri = resolve_uri(path)
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

        delay = retry_after ? Float(retry_after).clamp(0.0, MAX_RETRY_AFTER) : (2**attempts).to_f
        @sleeper.call(delay)
        true
      rescue ArgumentError, TypeError
        @sleeper.call((2**attempts).to_f)
        true
      end

      def reject_graphql_mutation!(body)
        query = body["query"] || body[:query]
        unless query.is_a?(String) && query.match?(/\A\s*(?:query(?:\s|\{|\()|\{)/i)
          raise ResponseError, "read-only GraphQL query body is required"
        end

        return unless query.match?(/\bmutation\b/i)

        raise ResponseError, "read-only HTTP transport rejects GraphQL mutation operations"
      end

      def validate_post!(path, body)
        uri = resolve_uri(path)
        raise ResponseError, "HTTP POST is restricted to the configured GraphQL endpoint" unless uri.path == @graphql_path
        unless body.is_a?(Hash) && (body.key?("query") || body.key?(:query))
          raise ResponseError, "read-only GraphQL query body is required"
        end

        reject_graphql_mutation!(body)
      end

      def resolve_uri(path)
        raw_path = String(path)
        parsed_path = URI.parse(raw_path)
        if parsed_path.scheme || parsed_path.host || raw_path.start_with?("//")
          raise ResponseError, "HTTP request path must be a relative path"
        end

        uri = @base_uri + raw_path
        unless uri.scheme == @base_uri.scheme && uri.host == @base_uri.host && uri.port == @base_uri.port
          raise ResponseError, "HTTP request path resolved outside the configured base URI"
        end

        uri
      rescue ArgumentError, URI::InvalidURIError
        raise ResponseError, "HTTP request path must be a relative path"
      end

      def normalize_graphql_path(path)
        value = String(path)
        value = "/#{value}" unless value.start_with?("/")
        value.chomp("/").then { |normalized| normalized.empty? ? "/" : normalized }
      rescue ArgumentError
        raise ResponseError, "GraphQL endpoint path must be a string"
      end
    end
  end
end
