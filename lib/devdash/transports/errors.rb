# frozen_string_literal: true

module Devdash
  module Transports
    module Sanitizer
      SECRET_PATTERN = /(?:authorization|access[_-]?token|api[_-]?key|client[_-]?secret|cookie|id[_-]?token|password|private[_-]?key|refresh[_-]?token|secret|token|x-api-key|x-auth-token)/i
      JSON_SECRET_PATTERN = /([\"'])(#{SECRET_PATTERN.source})\1(\s*:\s*)(\")(?:\\.|[^\"\\])*\4/i
      LEGACY_SECRET_PATTERN = /(?<![\"'])(#{SECRET_PATTERN.source})(?:\s*[:=]\s*|\s+)(?:Bearer\s+)?[^\s,]+/i

      module_function

      def sanitize(message)
        message.to_s
          .gsub(JSON_SECRET_PATTERN, '\\1\\2\\1\\3"[REDACTED]"')
          .gsub(LEGACY_SECRET_PATTERN) { |match| match.sub(/(#{SECRET_PATTERN.source})(?:\s*[:=]\s*|\s+)(?:Bearer\s+)?[^\s,]+/i, '\\1=[REDACTED]') }
      end
    end

    class Error < Devdash::Error; end
    class CommandError < Error; end
    class HttpError < Error; end
    class AuthenticationError < HttpError; end
    class RateLimitError < HttpError; end
    class TransientError < HttpError; end
    class ResponseError < HttpError; end
  end
end
