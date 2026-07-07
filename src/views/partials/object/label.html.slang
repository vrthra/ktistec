.label
  / the icon links to the actor's profile on their own instance
  / (`display_link`), complementing the name link in the content
  / partial, which stays on this server. `_top` keeps same-origin
  / (local actor) links from navigating inside the enclosing
  / turbo-frame.
  - if author != actor
    a data-turbo-frame="_top" href=actor.display_link title=actor.handle
      = actor_icon(actor, "ui avatar image")
  a data-turbo-frame="_top" href=author.display_link title=author.handle
    = actor_icon(author, "ui avatar image")
