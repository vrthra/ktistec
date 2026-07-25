require "../../../src/rules/view/follow_actor"
require "../../../src/models/relationship/content/follow/actor"
require "../../../src/models/relationship/content/notification/follow/actor"

require "../../spec_helper/base"
require "../../spec_helper/factory"
require "../../spec_helper/rule/view"

Spectator.describe Rules::View::FollowActor do
  include ViewSpecHelper

  setup_spec

  let(actor) { register.actor }
  let_create!(:actor, named: author)

  describe "registry" do
    it "is registered" do
      expect(Rules::View.registry).to contain(described_class.instance)
    end
  end

  describe "#type" do
    it "returns the actor-follow notification relationship type" do
      expect(subject.type).to eq(Relationship::Content::Notification::Follow::Actor.to_s)
    end
  end

  describe "#repositions?" do
    it "repositions" do
      expect(subject.repositions?).to be_true
    end
  end

  let(followed_at) { Time.utc(2026, 1, 1) }
  let(appeared_at) { followed_at + 1.hour }
  let_create!(:object, named: post, attributed_to: author, created_at: appeared_at)

  describe "#subjects" do
    it "publishes to the owner's notifications subject" do
      expect(subject.subjects("alice")).to eq(["/actors/alice/notifications"])
    end
  end

  describe "#project" do
    context "with no followed actor" do
      it "maps to no key" do
        expect(subject.project(post.iri)).to be_empty
      end
    end

    context "posted by an actor the owner follows" do
      let_create!(:follow_actor_relationship, named: nil, actor: actor, subject: author)

      it "maps to the owner/subject key" do
        expect(subject.project(post.iri)).to eq([{from_iri: actor.iri, to_iri: author.iri}])
      end

      context "and another owner who also follows the actor" do
        let_create(:account, named: other_account)
        let_create!(:follow_actor_relationship, named: nil, actor: other_account.actor, subject: author)

        it "maps to a key per owner" do
          expect(subject.project(post.iri)).to contain_exactly(
            {from_iri: actor.iri, to_iri: author.iri},
            {from_iri: other_account.actor.iri, to_iri: author.iri},
          )
        end
      end
    end
  end

  describe "#membership" do
    let_create!(:follow_actor_relationship, named: nil, actor: actor, subject: author, created_at: followed_at)

    context "given a post that appeared after the follow" do
      it "uses the appearance time as the membership timestamp" do
        expect(selected).to eq([{actor.iri, author.iri, post.created_at}])
      end

      context "from a blocked sender" do
        before_each { author.block! }

        it "does not select the post" do
          expect(selected).to be_empty
        end
      end

      context "attributed to the owner" do
        before_each { post.assign(attributed_to: actor).save }

        it "does not select the post" do
          expect(selected).to be_empty
        end
      end

      context "of a deleted object" do
        before_each { post.delete! }

        it "selects the post" do
          expect(selected).to eq([{actor.iri, author.iri, post.created_at}])
        end
      end

      context "and a second, later post from the same actor" do
        let_create!(:object, named: newer, attributed_to: author, created_at: appeared_at + 1.hour)

        it "uses the newer appearance time as the membership timestamp" do
          expect(selected).to eq([{actor.iri, author.iri, newer.created_at}])
        end
      end
    end

    context "given a post that appeared before the follow" do
      let(appeared_at) { followed_at - 1.hour }

      it "does not select the post" do
        expect(selected).to be_empty
      end
    end

    context "when scoped" do
      it "selects the full row for the key" do
        expect(selected({from_iri: actor.iri, to_iri: author.iri}))
          .to eq([{actor.iri, author.iri, post.created_at}])
      end

      it "selects nothing when the key does not qualify" do
        expect(selected({from_iri: actor.iri, to_iri: "absent"})).to be_empty
      end

      # intentional implementation test
      it "binds the owner and subject as parameters, never interpolating them" do
        _, args = subject.membership({from_iri: actor.iri, to_iri: author.iri})
        expect(args).to eq([actor.iri, author.iri])
      end
    end
  end
end
