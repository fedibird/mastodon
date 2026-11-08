import { openDropdownMenu, closeDropdownMenu } from '../actions/dropdown_menu';
import { fetchRelationships } from 'mastodon/actions/accounts';
import { openModal, closeModal } from '../actions/modal';
import { connect } from 'react-redux';
import ReactionPickerDropdown from '../components/reaction_picker_dropdown';
import { isUserTouching } from '../is_mobile';

import { changeSetting } from '../actions/settings';
import { useEmoji } from '../actions/emojis';
import { ensureCustomEmojis } from '../actions/custom_emojis';
import { getPickersEmoji, getFrequentlyUsedEmojis } from 'mastodon/selectors';

const mapStateToProps = state => ({
  pickersEmoji: getPickersEmoji(state),
  skinTone: state.getIn(['settings', 'skinTone']),
  frequentlyUsedEmojis: getFrequentlyUsedEmojis(state),
  openDropdownId: state.getIn(['dropdown_menu', 'openId']),
});

const mapDispatchToProps = (dispatch, { status, onPickEmoji, scrollKey }) => ({
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
      if (status) {
        dispatch(fetchRelationships([status.getIn(['account', 'id'])]));
      }

      // Touch reactions keep the existing history owner: the desktop dropdown
      // records useEmoji once, and this modal calls the status callback only.
      dispatch(isUserTouching() ? openModal('REACTION', {
        status: status,
        onPickEmoji: onPickEmoji,
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

export default connect(mapStateToProps, mapDispatchToProps)(ReactionPickerDropdown);
