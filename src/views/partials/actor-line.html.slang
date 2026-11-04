- _account = env.account?
.ui.actor.line data-controller="icon-load-error"
  - if actor.blocked?
    .avatar
      i.large.ban.icon
    .info
      em This actor is blocked!
  - else
    - if _account
      a.avatar href=remote_actor_path(actor)
        = actor_icon(actor)
    - else
      a.avatar href=Ktistec::SafeURI.from?(actor.iri)
        = actor_icon(actor)
    .info
      - if _account
        a.name href=remote_actor_path(actor) = emoji_name(actor)
      - else
        span.name = emoji_name(actor)
      a.handle.truncated href=Ktistec::SafeURI.from?(actor.iri) = actor.handle
      - if _account
        .activity
          - if env.request.path =~ /followers$/
            - if (_down = actor.down_at)
              crystal:
                _abs = _down.to_s("%B %d, %Y at %H:%M UTC")
                _rel = distance_of_time_in_words(_down)
              span.ui.label.broken
                | Down for
                time< datetime=_down.to_rfc3339 title=_abs = _rel
          - elsif env.request.path =~ /following$/
            crystal:
              _last_post = actor.last_known_post_at
              _status = activity_status(_last_post)
            - if _last_post
              crystal:
                _abs = _last_post.to_s("%B %d, %Y at %H:%M UTC")
                _rel = distance_of_time_in_words(_last_post)
              - if _status == :active
                a.submeta href=remote_actor_path(actor)
                  | Last posted
                  time<> datetime=_last_post.to_rfc3339 title=_abs = _rel
                  | ago
              - else
                a.ui.label href=remote_actor_path(actor) class=(_status == :quiet ? "stale" : "broken")
                  | Last posted
                  time<> datetime=_last_post.to_rfc3339 title=_abs = _rel
                  | ago
            - else
              a.ui.label.broken href=remote_actor_path(actor) No known posts
  .actions
    - if _account && _account.actor != actor
      - if env.request.path =~ /followers$/ && (follow_relationship = actor.follows?(_account.actor)) && follow_relationship.pending? && (_follow = follow_relationship.activity?)
        = activity_button "Accept", outbox_path(_account), _follow.iri, button_class: "ui tiny button accept"
        = activity_button "Reject", outbox_path(_account), _follow.iri, button_class: "ui tiny button reject"
        = form_button "Block", block_actor_path(actor), button_class: "ui tiny button dangerous", button_data: {"modal": "block.actor", "controller": "modal-action", "action": "click->modal-action#show"}
      - elsif (_follow = _account.actor.follows?(actor).try(&.activity?))
        = activity_button "Unfollow", outbox_path(_account), _follow.iri, type: "Undo", button_class: "ui tiny button"
      - else
        = activity_button "Follow", outbox_path(_account), actor.iri, button_class: "ui tiny button primary"
        = form_button "Block", block_actor_path(actor), button_class: "ui tiny button dangerous", button_data: {"modal": "block.actor", "controller": "modal-action", "action": "click->modal-action#show"}
    - elsif !_account && actor.local?
      = form_button "Follow", actor_remote_follow_path(actor), method: "GET", button_class: "ui tiny button primary"
