import { connect } from 'react-redux';
import EmojiPickerDropdown from '../components/emoji_picker_dropdown';
import { openModal, closeModal } from 'mastodon/actions/modal';
import { openDropdownMenu, closeDropdownMenu } from 'mastodon/actions/dropdown_menu';
import { changeSetting } from 'mastodon/actions/settings';
import { useEmoji } from 'mastodon/actions/emojis';
import { ensureCustomEmojis } from 'mastodon/actions/custom_emojis';
import { getPickersEmoji, getFrequentlyUsedEmojis } from 'mastodon/selectors';
import { isUserTouching } from 'mastodon/is_mobile';
import { focusNotedComposeFieldAfterModalClose } from 'mastodon/features/emoji/emoji_picker_focus';

const mapStateToProps = state => ({
  pickersEmoji: getPickersEmoji(state),
  skinTone: state.getIn(['settings', 'skinTone']),
  openDropdownId: state.getIn(['dropdown_menu', 'openId']),
  frequentlyUsedEmojis: getFrequentlyUsedEmojis(state),
});

const mapDispatchToProps = (dispatch, { onPickEmoji, scrollKey }) => ({
  onSkinTone: skinTone => {
    dispatch(changeSetting(['skinTone'], skinTone));
  },

  onPickEmoji: emoji => {
    dispatch(useEmoji(emoji));

    if (onPickEmoji) {
      onPickEmoji(emoji);
    }
  },

  onStandardActive: () => dispatch(ensureCustomEmojis()),

  onOpen(id, keyboard) {
    dispatch(() => {
      dispatch(isUserTouching() ? openModal('REACTION', {
        onPickEmoji: (emoji, event) => {
          const keepOpen = Boolean(event && (event.ctrlKey || event.metaKey));

          if (onPickEmoji) {
            onPickEmoji(emoji);
          }

          if (!keepOpen) {
            focusNotedComposeFieldAfterModalClose();
          }
        },
        onSkinTone: skinTone => {
          dispatch(changeSetting(['skinTone'], skinTone));
        },
      }) : openDropdownMenu(id, keyboard, scrollKey));
    });
  },

  onClose(id) {
    dispatch(closeModal('REACTION'));
    dispatch(closeDropdownMenu(id));
  },
});

export default connect(mapStateToProps, mapDispatchToProps)(EmojiPickerDropdown);
