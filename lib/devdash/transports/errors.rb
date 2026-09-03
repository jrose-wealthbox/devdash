# frozen_string_literal: true

module Devdash
  module Transports
    class Error < Devdash::Error; end
    class CommandError < Error; end
    class HttpError < Error; end
    class AuthenticationError < HttpError; end
    class RateLimitError < HttpError; end
    class TransientError < HttpError; end
    class ResponseError < HttpError; end
  end
end
