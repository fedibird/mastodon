import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { fetchFavouritedStatuses, expandFavouritedStatuses } from '../../actions/favourites';
import Column from '../ui/components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import StatusList from '../../components/status_list';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { debounce } from 'lodash';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { readTimelineLayout } from 'mastodon/utils/timeline_layout';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  heading: { id: 'column.favourites', defaultMessage: 'Favourites' },
});

const mapStateToProps = (state, { columnId }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns.findIndex(c => c.get('uuid') === uuid);
  const layoutMode = readTimelineLayout(state, columnId, 'favourited_statuses');
  const mediaLayout = layoutMode === 'media';
  const onlyMedia = mediaLayout || ((columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'favourited_statuses', 'other', 'onlyMedia']));
  const withoutMedia = mediaLayout ? false : ((columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'favourited_statuses', 'other', 'withoutMedia']));
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'favourited_statuses', 'columnWidth']);

  return {
    statusIds: state.getIn(['status_lists', 'favourites', 'items']),
    isLoading: state.getIn(['status_lists', 'favourites', 'isLoading'], true),
    hasMore: !!state.getIn(['status_lists', 'favourites', 'next']),
    onlyMedia,
    withoutMedia,
    columnWidth: columnWidth ?? defaultColumnWidth,
    layoutMode,
    mediaStatuses: mediaLayout ? state.get('statuses') : null,
  };
};

export default @connect(mapStateToProps)
@injectIntl
class Favourites extends ImmutablePureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    statusIds: ImmutablePropTypes.list.isRequired,
    intl: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    layoutMode: PropTypes.string,
    mediaStatuses: ImmutablePropTypes.map,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    hasMore: PropTypes.bool,
    isLoading: PropTypes.bool,
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
  };

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    dispatch(fetchFavouritedStatuses({ onlyMedia, withoutMedia }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, onlyMedia, withoutMedia } = this.props;

    if (prevProps.onlyMedia !== onlyMedia || prevProps.withoutMedia !== withoutMedia) {
      dispatch(fetchFavouritedStatuses({ onlyMedia, withoutMedia }));
    }
  }

  handlePin = () => {
    const { columnId, dispatch, onlyMedia, withoutMedia } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('FAVOURITES', { other: { onlyMedia, withoutMedia } }));
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
    this.props.dispatch(expandFavouritedStatuses());
  }, 300, { leading: true })

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['favourited_statuses', 'columnWidth'], value));
    }
  }

  render () {
    const { intl, statusIds, columnId, multiColumn, hasMore, isLoading, columnWidth, withoutMedia, layoutMode, mediaStatuses } = this.props;
    const pinned = !!columnId;

    const emptyMessage = <FormattedMessage id='empty_column.favourited_statuses' defaultMessage="You don't have any favourite posts yet. When you favourite one, it will show up here." />;

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.heading)} columnWidth={columnWidth}>
        <ColumnHeader
          columnId={columnId}
          layoutScope='favourited_statuses'
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
          layoutMode={layoutMode}
          mediaStatuses={mediaStatuses}
          trackScroll={!pinned}
          statusIds={statusIds}
          scrollKey={`favourited_statuses-${columnId}`}
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
