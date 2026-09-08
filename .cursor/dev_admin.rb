# Idempotently create a confirmed development admin account.
# Email is intentionally port-free (admin@localhost) so it passes validation
# even though LOCAL_DOMAIN carries a :3000 port for correct local URLs.
email = "admin@localhost"

unless User.exists?(email: email)
  account = Account.where(username: "admin").first_or_initialize(username: "admin")
  account.save(validate: false)

  User.create!(
    email: email,
    password: "mastodonadmin",
    password_confirmation: "mastodonadmin",
    confirmed_at: Time.now.utc,
    admin: true,
    account: account,
    agreement: true,
    approved: true
  )
  puts "[dev_admin] Created #{email} (password: mastodonadmin)"
else
  puts "[dev_admin] #{email} already exists"
end
