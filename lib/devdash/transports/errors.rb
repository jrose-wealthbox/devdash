# frozen_string_literal: true

module Devdash
  module Transports
    module Sanitizer
      SECRET_PATTERN = /(?:authorization|access_token|api[_-]?key|x-api-key|token)/i

      module_function

      def sanitize(message)
        message.to_s.gsub(/(#{SECRET_PATTERN.source})(?:\s*[:=]\s*|\s+)(?:Bearer\s+)?[^\s,]+/i, "\\1=[REDACTED]")
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
