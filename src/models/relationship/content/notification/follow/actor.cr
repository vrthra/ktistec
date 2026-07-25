require "../../../../relationship"
require "../../notification"

class Relationship
  class Content
    class Notification < Relationship
      class Follow < Notification
        class Actor < Notification
          # The actor whose new post triggered the notification.
          #
          belongs_to subject, class_name: ActivityPub::Actor, foreign_key: to_iri, primary_key: iri
          validates(subject) { "missing: #{to_iri}" unless subject? }
        end
      end
    end
  end
end
