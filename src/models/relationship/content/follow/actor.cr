require "../../../relationship"
require "../../../activity_pub/actor"
require "../../../../framework/observable"

class Relationship
  class Content
    class Follow
      class Actor < Relationship
        belongs_to actor, class_name: ActivityPub::Actor, foreign_key: from_iri, primary_key: iri
        validates(actor) { "missing: #{from_iri}" unless actor? }

        # The actor whose new posts trigger a notification.
        #
        belongs_to subject, class_name: ActivityPub::Actor, foreign_key: to_iri, primary_key: iri
        validates(subject) { "missing: #{to_iri}" unless subject? }

        OBSERVERS = Ktistec::Observable::Registry(Relationship::Content::Follow::Actor).new

        def after_destroy
          Relationship::Content::Follow::Actor::OBSERVERS.notify(:destroy, self)
        end
      end
    end
  end
end
