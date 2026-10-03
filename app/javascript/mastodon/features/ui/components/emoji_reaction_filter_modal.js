import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import EmojiReactionFilterPicker from '../../emoji_reactioned_statuses/components/emoji_filter_picker';
import { getAppliedEmojiReactionFilters, getEmojiReactionCatalogState, getPreferredEmojiReactionFilters, saveEmojiReactionFilters, savePreferredEmojiReactionFilters } from '../../emoji_reactioned_statuses/utils';

const mapStateToProps = (state, { columnId }) => ({
  appliedEmojis: getAppliedEmojiReactionFilters(state, columnId),
  preferredEmojis: getPreferredEmojiReactionFilters(state),
  ...getEmojiReactionCatalogState(state),
});

const mapDispatchToProps = (dispatch, { columnId }) => ({
  onApply(draft) {
    dispatch(saveEmojiReactionFilters(columnId, draft));
  },

  onTogglePreferred(next) {
    dispatch(savePreferredEmojiReactionFilters(next));
  },
});

class EmojiReactionFilterModal extends React.PureComponent {

  static propTypes = {
    catalogItems: ImmutablePropTypes.list,
    appliedEmojis: ImmutablePropTypes.list,
    preferredEmojis: ImmutablePropTypes.list,
    isLoading: PropTypes.bool,
    loaded: PropTypes.bool,
    error: PropTypes.any,
    onApply: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onTogglePreferred: PropTypes.func.isRequired,
  };

  handleApply = (draft) => {
    this.props.onApply(draft);
    this.props.onClose();
  };

  render() {
    const { catalogItems, appliedEmojis, preferredEmojis, isLoading, loaded, error, onClose, onTogglePreferred } = this.props;

    return (
      <div className='modal-root__modal emoji-reaction-filter-modal'>
        <EmojiReactionFilterPicker
          catalogItems={catalogItems}
          appliedEmojis={appliedEmojis}
          preferredEmojis={preferredEmojis}
          isLoading={isLoading}
          loaded={loaded}
          error={error}
          onApply={this.handleApply}
          onClose={onClose}
          onTogglePreferred={onTogglePreferred}
        />
      </div>
    );
  }

}

export default connect(mapStateToProps, mapDispatchToProps)(EmojiReactionFilterModal);
