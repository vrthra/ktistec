require "../framework"

class WellKnownController
  include Balloon::Controller

  skip_auth ["/.well-known/*"]

  get "/.well-known/webfinger" do |env|
    domain = (host =~ /\/\/([^\/]+)$/) && $1

    server_error unless $1
    bad_request unless resource = env.params.query["resource"]?
    bad_request unless resource =~ /^acct:([^@]+)@(#{domain})$/

    account = Account.find(username: $1)

    message = {
      subject: resource,
      aliases: [
        "#{host}/accounts/#{$1}"
      ],
      links: [{
                rel: "self",
                href: "#{host}/accounts/#{$1}",
                type: "application/activity+json"
              }, {
                rel: "http://webfinger.net/rel/profile-page",
                href: "#{host}/accounts/#{$1}",
                type: "text/html"
              }]
    }
    env.response.content_type = "application/jrd+json"
    message.to_json
  rescue Balloon::Model::NotFound
    not_found
  end
end
