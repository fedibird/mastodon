Fabricator(:domain_allow) do
  domain { sequence(:domain) { |i| "#{i}#{Faker::Internet.domain_name}" } }
end
