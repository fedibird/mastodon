Doorkeeper::Application.create!(name: 'Web', superapp: true, redirect_uri: Doorkeeper.configuration.native_redirect_uri, scopes: 'read write follow push')

domain = ENV['LOCAL_DOMAIN'] || Rails.configuration.x.local_domain
account = Account.find_or_initialize_by(id: -99, actor_type: 'Application', locked: true, username: domain)
account.save!

load Rails.root.join('db', 'seeds', '03_roles.rb')

if Rails.env.development?
  admin = Account.where(username: 'admin').first_or_initialize(username: 'admin')
  admin.save(validate: false)
  user = User.where(email: "admin@#{domain}").first_or_initialize(email: "admin@#{domain}", password: 'mastodonadmin', password_confirmation: 'mastodonadmin', confirmed_at: Time.now.utc, admin: true, account: admin, agreement: true, approved: true)
  user.admin = true
  user.moderator = false
  user.role_id = UserRole.find_by!(name: 'Owner').id
  user.save!
end
