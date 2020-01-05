class Form::AccountSubscribe
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :id, :integer
  attribute :acct, :string
  attribute :show_reblogs, :boolean, default: true
  attribute :list_id, :integer

  def acct=(val)
    super(val.to_s.strip.gsub(/\A@/, ''))
  end
end
