import { connect } from 'react-redux';
import { openDropdownMenu, closeDropdownMenu } from '../../../actions/dropdown_menu';
import { openModal, closeModal } from '../../../actions/modal';
import { fetchEmojiReactionEmojiCatalog } from '../../../actions/emoji_reactions';
import { isUserTouching } from 'mastodon/is_mobile';
import EmojiFilterDropdown from '../components/emoji_filter_dropdown';
import {
  getAppliedEmojiReactionFilters,
  getEmojiReactionCatalogState,
  getPreferredEmojiReactionFilters,
  saveEmojiReactionFilters,
  savePreferredEmojiReactionFilters,
} from '../utils';

const mapStateToProps = (state, { columnId }) => {
  const modalProps = state.getIn(['modal', 0, 'modalProps']);

  return {
    emojis: getAppliedEmojiReactionFilters(state, columnId),
    preferredEmojis: getPreferredEmojiReactionFilters(state),
    ...getEmojiReactionCatalogState(state),
    openDropdownId: state.getIn(['dropdown_menu', 'openId']),
    modalType: state.getIn(['modal', 0, 'modalType']),
    modalColumnId: modalProps && (typeof modalProps.get === 'function' ? modalProps.get('columnId') : modalProps.columnId),
  };
};

const mapDispatchToProps = (dispatch, { columnId }) => ({
  onApply(draft) {
    dispatch(saveEmojiReactionFilters(columnId, draft));
  },

  onChange(next) {
    dispatch(saveEmojiReactionFilters(columnId, next));
  },

  onTogglePreferred(next) {
    dispatch(savePreferredEmojiReactionFilters(next));
  },

  onOpen(id, keyboard) {
    dispatch(fetchEmojiReactionEmojiCatalog());

    if (isUserTouching()) {
      dispatch(openModal('EMOJI_REACTION_FILTER', { columnId }));
    } else {
      dispatch(openDropdownMenu(id, keyboard));
    }
  },

  onClose(id) {
    dispatch(closeModal('EMOJI_REACTION_FILTER'));
    dispatch(closeDropdownMenu(id));
  },
});

export default connect(mapStateToProps, mapDispatchToProps)(EmojiFilterDropdown);
