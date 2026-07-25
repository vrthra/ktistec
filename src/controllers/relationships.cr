require "../framework/controller"

class RelationshipsController
  include Ktistec::Controller

  skip_auth ["/actors/:username/following"], GET
  skip_auth ["/actors/:username/followers"], GET

  # Followers/following are rendered as a single, unpaginated list
  # (see `relationships/actors.html.slang`). This caps how many rows
  # that list will ever fetch/render in one request.
  #
  SHOW_ALL_LIMIT = 1000

  # Authorizes account access for public relationship data.
  #
  # Returns the account if it exists, `nil` otherwise.
  #
  # Used for viewing relationships (following/followers) where
  # public/private filtering is handled separately.
  #
  private def self.get_account(env)
    Account.find?(username: env.params.url["username"])
  end

  # Authorizes account access for private relationship data.
  #
  # Returns the account if the authenticated user owns it, `nil`
  # otherwise.
  #
  # Used for viewing relationships (likes/shares) which should only be
  # accessible to the account owner.
  #
  private def self.get_account_with_ownership(env)
    if (account = Account.find?(username: env.params.url["username"]))
      if env.account? == account
        account
      end
    end
  end

  # Returns the validated regular expression search parameter and an
  # error message, at most one of which is non-nil.
  #
  # The pattern must be proven to compile here: the sqlite3 shard's
  # `regexp` SQL function compiles it inside a C callback, where a
  # raised exception cannot safely unwind. Matching is made
  # case-insensitive by default with an inline `(?i)` flag -- a
  # pattern can override with `(?-i)`.
  #
  private def self.search_param(env) : {String?, String?}
    if (pattern = env.params.query["search"]?.presence)
      begin
        Regex.new(pattern)
        {"(?i)#{pattern}", nil}
      rescue ex : ArgumentError
        {nil, "invalid regular expression: #{ex.message}"}
      end
    else
      {nil, nil}
    end
  end

  get "/actors/:username/following" do |env|
    unless (account = get_account(env))
      gone
    end

    search, search_error = search_param(env)
    related = account.actor.all_following(limit: SHOW_ALL_LIMIT, public: env.account? != account, search: search)
    ok "relationships/actors", env: env, related: related, title: "Following", search: env.params.query["search"]?, search_error: search_error
  end

  get "/actors/:username/followers" do |env|
    unless (account = get_account(env))
      gone
    end

    search, search_error = search_param(env)
    related = account.actor.all_followers(limit: SHOW_ALL_LIMIT, public: env.account? != account, search: search)
    ok "relationships/actors", env: env, related: related, title: "Followers", search: env.params.query["search"]?, search_error: search_error
  end

  get "/actors/:username/likes" do |env|
    unless (account = get_account_with_ownership(env))
      not_found
    end

    objects = account.actor.likes(**cursor_pagination_params(env))
    ok "relationships/objects", env: env, objects: objects, title: "Likes"
  end

  get "/actors/:username/shares" do |env|
    unless (account = get_account_with_ownership(env))
      not_found
    end

    objects = account.actor.announces(**cursor_pagination_params(env))
    ok "relationships/objects", env: env, objects: objects, title: "Shares"
  end
end
