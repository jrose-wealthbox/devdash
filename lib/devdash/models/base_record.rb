# frozen_string_literal: true

module Devdash
  module Models
    class BaseRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  end
end
