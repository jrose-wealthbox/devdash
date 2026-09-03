# frozen_string_literal: true
module Devdash
  module Models
    class Commit < BaseRecord
      belongs_to :repository
      belongs_to :author, class_name: "Devdash::Models::Person", optional: true
      belongs_to :committer, class_name: "Devdash::Models::Person", optional: true
      belongs_to :pull_request, optional: true
      has_many :commit_files, dependent: :delete_all
    end
  end
end
