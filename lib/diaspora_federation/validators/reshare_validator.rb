# frozen_string_literal: true

module DiasporaFederation
  module Validators
    # This validates a {Entities::Reshare}.
    class ReshareValidator < OptionalAwareValidator
      include Validation

      rule :root_author, :diaspora_id

      rule :root_guid, :guid

      rule :author, :diaspora_id

      rule :guid, :guid
    end
  end
end
