import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { fetchEmojiReactionedStatuses, expandEmojiReactionedStatuses, fetchEmojiReactionEmojiCatalog, emojiReactionedStatusesListKey, pinnedEmojiReactionColumnParams } from '../../actions/emoji_reactions';
import Column from '../ui/components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn, changeColumnParams } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import StatusList from '../../components/status_list';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { debounce } from 'lodash';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { List as ImmutableList, is } from 'immutable';

const EMPTY_EMOJI_LIST = ImmutableList();
const EMPTY_STATUS_LIST = ImmutableList();

const emojiFilterList = value => {
  if (!value) {
    return EMPTY_EMOJI_LIST;
  }

  return ImmutableList.isList(value) ? value : ImmutableList(value);
};

const messages = defineMessages({
  heading: { id: 'column.emoji_reactions', defaultMessage: 'EmojiReactions' },
});

const mapStateToProps = (state, { columnId }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns ? columns.findIndex(c => c.get('uuid') === uuid) : -1;
  const pinned = columnId && index >= 0;
  const onlyMedia = pinned ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'emoji_reactioned_statuses', 'other', 'onlyMedia']);
  const withoutMedia = pinned ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'emoji_reactioned_statuses', 'other', 'withoutMedia']);
  const columnWidth = pinned ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'emoji_reactioned_statuses', 'columnWidth']);
  const emojis = emojiFilterList(pinned ? columns.get(index).getIn(['params', 'emojis']) : state.getIn(['settings', 'emoji_reactioned_statuses', 'emojis']));
  const listKey = emojiReactionedStatusesListKey(columnId);
  const list = state.getIn(['emoji_reactioned_statuses', 'lists', listKey]);

  return {
    listKey,
    emojis,
    statusIds: list ? list.get('items') : EMPTY_STATUS_LIST,
    isLoading: list ? list.get('isLoading') : false,
    hasMore: !!(list && list.get('next')),
    stale: list ? list.get('stale') : false,
    onlyMedia,
    withoutMedia,
    columnWidth: columnWidth ?? defaultColumnWidth,
  };
};

export default @connect(mapStateToProps)
@injectIntl
class EmojiReactions extends ImmutablePureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    statusIds: ImmutablePropTypes.list.isRequired,
    intl: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    hasMore: PropTypes.bool,
    isLoading: PropTypes.bool,
    stale: PropTypes.bool,
    listKey: PropTypes.string,
    emojis: ImmutablePropTypes.list,
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
    stale: false,
  };

  componentDidMount () {
    const { dispatch, listKey, emojis, onlyMedia, withoutMedia } = this.props;

    dispatch(fetchEmojiReactionEmojiCatalog());
    dispatch(fetchEmojiReactionedStatuses({ listKey, emojis, onlyMedia, withoutMedia }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, listKey, emojis, onlyMedia, withoutMedia, stale, isLoading } = this.props;
    const filtersChanged = prevProps.listKey !== listKey
      || prevProps.onlyMedia !== onlyMedia
      || prevProps.withoutMedia !== withoutMedia
      || !is(prevProps.emojis, emojis);

    if (filtersChanged || (stale && !isLoading)) {
      dispatch(fetchEmojiReactionedStatuses({ listKey, emojis, onlyMedia, withoutMedia }));
    }

    if (stale && !isLoading) {
      dispatch(fetchEmojiReactionEmojiCatalog());
    }
  }

  handlePin = () => {
    const { columnId, dispatch, emojis, onlyMedia, withoutMedia } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('EMOJI_REACTIONS', pinnedEmojiReactionColumnParams({ emojis, onlyMedia, withoutMedia })));
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  setRef = c => {
    this.column = c;
  }

  handleLoadMore = debounce(() => {
    this.props.dispatch(expandEmojiReactionedStatuses(this.props.listKey));
  }, 300, { leading: true })

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['emoji_reactioned_statuses', 'columnWidth'], value));
    }
  }

  render () {
    const { intl, statusIds, columnId, multiColumn, hasMore, isLoading, columnWidth, withoutMedia } = this.props;
    const pinned = !!columnId;

    const emptyMessage = <FormattedMessage id='empty_column.emoji_reactioned_statuses' defaultMessage="You don't have any reaction posts yet. When you reaction one, it will show up here." />;

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.heading)} columnWidth={columnWidth}>
        <ColumnHeader
          icon='star'
          title={intl.formatMessage(messages.heading)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
          showBackButton
        >
          <ColumnSettingsContainer columnId={columnId} />
        </ColumnHeader>

        <StatusList
          trackScroll={!pinned}
          statusIds={statusIds}
          scrollKey={`emoji_reactioned_statuses-${columnId}`}
          hasMore={hasMore}
          isLoading={isLoading}
          onLoadMore={this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
          showCard={!withoutMedia}
        />
      </Column>
    );
  }

}
