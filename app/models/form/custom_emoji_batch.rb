# frozen_string_literal: true

class Form::CustomEmojiBatch
  include ActiveModel::Model
  include Authorization
  include AccountableConcern

  attr_accessor :custom_emoji_ids, :action, :current_account,
                :category_id, :category_name, :visible_in_picker,
                :keyword_action, :keyword_action_value,
                :description, :creator, :copy_permission, :license, :misskey_license, :copyright_notice, :credit_text, :usage_info, :related_link

  SHORTCODE_MATCH_TYPES   = %w(include start_with end_with match)
  KEYWORD_ACTIONS         = %w(apend prepend remove overwrite)
  LICENSE_ACTIONS         = %w(apend prepend remove overwrite)
  COPY_PERMISSION_ACTIONS = %w(prompt none allow deny conditional)

  def save
    case action
    when 'update'
      update!
    when 'list'
      list!
    when 'unlist'
      unlist!
    when 'enable'
      enable!
    when 'disable'
      disable!
    when 'copy'
      copy!
    when 'copy_ow'
      copy_ow!
    when 'delete'
      delete!
    when 'fetch'
      fetch!
    end
  end

  private

  def custom_emojis
    @custom_emojis ||= CustomEmoji.where(id: custom_emoji_ids)
  end

  def update!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :update?) }

    category = begin
      if category_id.present?
        CustomEmojiCategory.find(category_id)
      elsif category_name.present?
        CustomEmojiCategory.find_or_create_by!(name: category_name)
      end
    end

    custom_emojis.each do |custom_emoji|
      custom_emoji.category_id      = category&.id              if category.present?
      custom_emoji.aliases          = applied_aliases(custom_emoji)
      custom_emoji.description      = a_strip(description)      if description.present?
      custom_emoji.creator          = a_strip(creator)          if creator.present?
      custom_emoji.copy_permission  = copy_permission           if COPY_PERMISSION_ACTIONS.include?(copy_permission) && copy_permission != 'prompt'
      custom_emoji.license          = a_strip(license)          if license.present?
      custom_emoji.misskey_license  = a_strip(misskey_license)  if misskey_license.present?
      custom_emoji.copyright_notice = a_strip(copyright_notice) if copyright_notice.present?
      custom_emoji.credit_text      = a_strip(credit_text)      if credit_text.present?
      custom_emoji.usage_info       = a_strip(usage_info)       if usage_info.present?
      custom_emoji.related_link     = a_strip(related_link)     if related_link.present?      
      custom_emoji.save
      log_action :update, custom_emoji
    end
  end

  def a_strip(str)
    str == '*' ? '' : str.strip
  end

  def applied_aliases(custom_emoji)
    case keyword_action
    when 'apend'
      (custom_emoji.aliases + keyword_action_value.split(' ')).uniq
    when 'prepend'
      aliases = keyword_action_value.split(' ')
      aliases.concat(custom_emoji.aliases - aliases)
    when 'remove'
      custom_emoji.aliases - keyword_action_value.split(' ')
    when 'overwrite'
      keyword_action_value.split(' ')
    else
      custom_emoji.aliases
    end
  end

  def list!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :update?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.update(visible_in_picker: true)
      log_action :update, custom_emoji
    end
  end

  def unlist!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :update?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.update(visible_in_picker: false)
      log_action :update, custom_emoji
    end
  end

  def enable!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :enable?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.update(disabled: false)
      log_action :enable, custom_emoji
    end
  end

  def disable!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :disable?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.update(disabled: true)
      log_action :disable, custom_emoji
    end
  end

  def copy!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :copy?) }

    custom_emojis.each do |custom_emoji|
      copied_custom_emoji = custom_emoji.copy!
      log_action :create, copied_custom_emoji
    end
  end

  def copy_ow!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :copy?) }

    custom_emojis.each do |custom_emoji|
      copied_custom_emoji = custom_emoji.copy!(on_existance_action: :overwrite)
      log_action :create, copied_custom_emoji
    end
  end

  def delete!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :destroy?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.destroy
      log_action :destroy, custom_emoji
    end
  end

  def fetch!
    custom_emojis.each { |custom_emoji| authorize(custom_emoji, :fetch?) }

    custom_emojis.each do |custom_emoji|
      custom_emoji.fetch
      log_action :fetch, custom_emoji
    end
  end
end
