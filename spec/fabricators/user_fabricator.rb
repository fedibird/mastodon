Fabricator(:user) do
  account
  email        { sequence(:email) { |i| "#{i}#{Faker::Internet.email}" } }
  password     "123456789"
  confirmed_at { Time.zone.now }
  current_sign_in_at { Time.zone.now }
  agreement    true
end
