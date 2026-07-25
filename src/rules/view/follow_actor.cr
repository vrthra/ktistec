require "../view"

module Rules
  abstract class View
    # The actor-follow notification view.
    #
    # There is one row per actor the owner follows for notifications,
    # bumped to the recency of the newest qualifying object the actor
    # posted.
    #
    class FollowActor < View
      include NotifiesNotifications

      TYPE   = "Relationship::Content::Notification::Follow::Actor"
      FOLLOW = "Relationship::Content::Follow::Actor"

      class_getter instance : FollowActor { new }

      def type : String
        TYPE
      end

      def repositions? : Bool
        true
      end

      def membership(key : Key? = nil) : {String, Array(DB::Any)}
        if key
          scope = "AND f.from_iri = ? AND f.to_iri = ?"
          args = Array(DB::Any){key[:from_iri], key[:to_iri]}
        else
          scope = ""
          args = Array(DB::Any).new
        end
        sql = <<-SQL
          SELECT f.from_iri AS from_iri,
                 f.to_iri   AS to_iri,
                 MAX(o.created_at) AS position
            FROM relationships f
            JOIN accounts c ON c.iri = f.from_iri
            JOIN objects o  ON o.attributed_to_iri = f.to_iri
                           AND o.attributed_to_iri <> f.from_iri
            JOIN actors s   ON s.iri = o.attributed_to_iri
                           AND s.blocked_at IS NULL
           WHERE f.type = '#{FOLLOW}'
             AND o.created_at > f.created_at
             #{scope}
           GROUP BY f.from_iri, f.to_iri
        SQL
        {sql, args}
      end

      def project(object_iri : String) : Array(Key)
        rows = Ktistec.database.query_all(<<-SQL, object_iri, as: {String, String})
          SELECT f.from_iri, f.to_iri
            FROM objects o
            JOIN relationships f ON f.type = '#{FOLLOW}' AND f.to_iri = o.attributed_to_iri
            JOIN accounts c ON c.iri = f.from_iri
           WHERE o.iri = ?
          SQL
        rows.map { |(owner, subject)| {from_iri: owner, to_iri: subject} }
      end
    end

    register(FollowActor.instance)
  end
end
