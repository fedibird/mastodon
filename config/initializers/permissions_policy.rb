# Define an application-wide HTTP permissions policy. For further
# information see https://developers.google.com/web/updates/2018/06/feature-policy
#
# External embed fullscreen is delegated only on that iframe
# (externalEmbedFrameProps in external_embed_player.js: allow="fullscreen *"
# and the legacy allowfullscreen attribute). Do not enable the block below.
# fullscreen :none disables the feature for the whole document. fullscreen :self
# sends Permissions-Policy: fullscreen=(self), and a parent header allowlist
# that omits the player origin cannot be widened by the iframe allow attribute.
# config/environments/production.rb currently sends interest-cohort=() only.
# That header does not grant or deny fullscreen. A reverse proxy in front of
# a deployed instance is outside this file and is not measured here.
#
# Rails.application.config.permissions_policy do |f|
#   f.camera      :none
#   f.gyroscope   :none
#   f.microphone  :none
#   f.usb         :none
#   f.fullscreen  :self
#   f.payment     :self, "https://secure.example.com"
# end
