- content_for "title" do
  = title
- if (_account = env.account?) && _account.username == env.params.url["username"]?
  / an action-less GET form submits to the current path and replaces
  / the query string, discarding any stale pagination cursors
  form.ui.form method="GET"
    .ui.fluid.action.input
      input type="text" name="search" value=search placeholder="Filter with a regular expression (case-insensitive)"
      button.ui.icon.button type="submit"
        i.search.icon
  - if search_error
    .ui.negative.message
      = search_error
- if related.empty? && search.presence
  .ui.basic.very.padded.center.aligned.segment
    .ui.icon.header
      i.search.icon
      | Nothing matches the search.
- elsif related.empty? && title == "Followers"
  .ui.basic.very.padded.center.aligned.segment
    - if env.account?
      .ui.icon.header
        i.exclamation.icon
        | No one is following you yet.
      .ui.text
        | This page lists your followers.
    - else
      .ui.icon.header
        i.exclamation.icon
        | There is nothing here yet.
- elsif related.empty? && title == "Following"
  .ui.basic.very.padded.center.aligned.segment
    - if env.account?
      .ui.icon.header
        i.exclamation.icon
        | You're not following anyone yet.
      .ui.text
        | This page lists people you are following.
    - else
      .ui.icon.header
        i.exclamation.icon
        | There is nothing here yet.
- else
  h1= title
  .ui.actor.lines
    - related.each do |actor|
      - partial "partials/actor-line"
