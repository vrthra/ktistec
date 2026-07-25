require "../../../../../../src/models/relationship/content/notification/follow/actor"

require "../../../../../spec_helper/base"
require "../../../../../spec_helper/factory"

Spectator.describe Relationship::Content::Notification::Follow::Actor do
  setup_spec

  let_create(:actor, named: :owner)
  let_create(:actor, named: :subject)

  let(options) do
    {
      owner:   owner,
      subject: subject,
    }
  end

  context "validation" do
    it "rejects missing owner" do
      new_relationship = described_class.new(from_iri: "", subject: subject)
      expect(new_relationship.valid?).to be_false
      expect(new_relationship.errors.keys).to contain("owner")
    end

    it "rejects missing subject" do
      new_relationship = described_class.new(owner: owner, to_iri: "")
      expect(new_relationship.valid?).to be_false
      expect(new_relationship.errors.keys).to contain("subject")
    end

    it "successfully validates instance" do
      new_relationship = described_class.new(**options)
      expect(new_relationship.valid?).to be_true
    end
  end
end
