import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';
import ColumnSettingsContainer from './containers/column_settings_container';
import { expandHashtagTimeline, clearTimeline } from 'mastodon/actions/timelines';
import { hashtagSplitContextKey, hashtagTimelineId } from 'mastodon/actions/timeline_ids';
import { addColumn, removeColumn, moveColumn } from 'mastodon/actions/columns';
import { injectIntl, FormattedMessage, defineMessages } from 'react-intl';
import { connectHashtagStream } from 'mastodon/actions/streaming';
import { isEqual } from 'lodash';
import { fetchHashtag, followHashtag, unfollowHashtag } from 'mastodon/actions/tags';
import Icon from 'mastodon/components/icon';
import classNames from 'classnames';
import { defaultColumnWidth, followTagModal, unfollowTagModal, isAdministrator } from 'mastodon/initial_state';
import PortableComposer from '../compose/portable_composer';
import PortableComposerToggle from '../compose/components/portable_composer_toggle';
import { captureVisibleStatusAnchor, columnNodeFromRef, scheduleStatusAnchorRestore } from '../compose/components/portable_composer_scroll';
import { selectPortableComposerVisible } from 'mastodon/selectors/composer';
import { buildHashtagTimelinePostingContext } from 'mastodon/posting_context/hashtag';
import { normalizeManagedHashtagName } from 'mastodon/posting_context/managed_hashtags';
import { openModal } from 'mastodon/actions/modal';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  followHashtag: { id: 'hashtag.follow', defaultMessage: 'Follow hashtag' },
  unfollowHashtag: { id: 'hashtag.unfollow', defaultMessage: 'Unfollow hashtag' },
  followHashtagConfirm: { id: 'confirmations.follow_hashtag.confirm', defaultMessage: 'Follow hastag' },
  unfollowHashtagConfirm: { id: 'confirmations.unfollow_hashtag.confirm', defaultMessage: 'Unfollow hashtag' },
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const hashtagComposerId = (id, columnId) => (
  columnId ? `portable:hashtag-column:${columnId}` : `portable:hashtag-route:${normalizeManagedHashtagName(id)}`
);

const mapStateToProps = (state, { columnId, params }) => {
  const columns = state.getIn(['settings', 'columns']);
  const index = columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'hashtag', 'columnWidth']);

  return {
    hasUnread: state.getIn(['timelines', hashtagTimelineId(params.id), 'unread']) > 0,
    tag: state.getIn(['tags', params.id]),
    columnWidth: columnWidth ?? defaultColumnWidth,
    splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'hashtag', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
    composerVisible: selectPortableComposerVisible(state, hashtagComposerId(params.id, columnId)),
  };
};

class HashtagTimeline extends React.PureComponent {

  disconnects = [];

  static propTypes = {
    params: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    hasUnread: PropTypes.bool,
    tag: ImmutablePropTypes.map,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    intl: PropTypes.object,
    splitRatio: PropTypes.number,
    composerVisible: PropTypes.bool,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('HASHTAG', { id: this.props.params.id }));
    }
  }

  title = () => {
    const { id } = this.props.params;
    const title  = [id];

    if (this.additionalFor('any')) {
      title.push(' ', <FormattedMessage key='any' id='hashtag.column_header.tag_mode.any'  values={{ additional: this.additionalFor('any') }} defaultMessage='or {additional}' />);
    }

    if (this.additionalFor('all')) {
      title.push(' ', <FormattedMessage key='all' id='hashtag.column_header.tag_mode.all'  values={{ additional: this.additionalFor('all') }} defaultMessage='and {additional}' />);
    }

    if (this.additionalFor('none')) {
      title.push(' ', <FormattedMessage key='none' id='hashtag.column_header.tag_mode.none' values={{ additional: this.additionalFor('none') }} defaultMessage='without {additional}' />);
    }

    return title;
  }

  additionalFor = (mode) => {
    const { tags } = this.props.params;

    if (tags && (tags[mode] || []).length > 0) {
      return tags[mode].map(tag => tag.value).join('/');
    } else {
      return '';
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['hashtag', 'splitRatio'], ratio));
  }

  _subscribe (dispatch, id, tags = {}) {
    let any  = (tags.any || []).map(tag => tag.value);
    let all  = (tags.all || []).map(tag => tag.value);
    let none = (tags.none || []).map(tag => tag.value);

    [id, ...any].map(tag => {
      this.disconnects.push(dispatch(connectHashtagStream(id, tag, status => {
        let tags = status.tags.map(tag => tag.name);

        return all.filter(tag => tags.includes(tag)).length === all.length &&
               none.filter(tag => tags.includes(tag)).length === 0;
      })));
    });
  }

  _unsubscribe () {
    this.disconnects.map(disconnect => disconnect());
    this.disconnects = [];
  }

  _load() {
    const { dispatch } = this.props;
    const { id, tags } = this.props.params;

    this._subscribe(dispatch, id, tags);
    dispatch(expandHashtagTimeline(id, { tags }));
    dispatch(fetchHashtag(id));
  }

  componentDidMount () {
    this._load();
  }

  componentDidUpdate (prevProps) {
    const previousId = prevProps.params.id;
    const { id, tags } = this.props.params;
    const idChanged = previousId !== id;
    const tagsChanged = !isEqual(prevProps.params.tags, tags);

    this.restoreComposerScroll(prevProps, idChanged);

    if (idChanged || tagsChanged) {
      this._unsubscribe();

      if (!idChanged) {
        this.props.dispatch(clearTimeline(hashtagTimelineId(id)));
      }

      this._load();
    }
  }

  componentWillUnmount () {
    if (this.cancelStatusAnchor) {
      this.cancelStatusAnchor();
      this.cancelStatusAnchor = null;
    }

    this._unsubscribe();
  }

  bindColumn = (column) => {
    this.columnNode = columnNodeFromRef(column);

    if (this.forwardColumnRef) {
      this.forwardColumnRef(column);
    }
  }

  restoreComposerScroll = (prevProps, idChanged) => {
    if (idChanged) {
      this.statusAnchor = null;
      return;
    }

    const wasMounted = isAdministrator && prevProps.composerVisible;
    const isMounted = isAdministrator && this.props.composerVisible;

    if (wasMounted === isMounted) {
      return;
    }

    if (this.cancelStatusAnchor) {
      this.cancelStatusAnchor();
    }

    this.cancelStatusAnchor = scheduleStatusAnchorRestore(this.statusAnchor);
    this.statusAnchor = null;
  }

  handleLoadMore = maxId => {
    const { dispatch, params } = this.props;
    const { id, tags }  = params;

    dispatch(expandHashtagTimeline(id, { maxId, tags }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, params } = this.props;
    const { id, tags } = params;

    dispatch(expandHashtagTimeline(id, { maxId, tags, timelineId: this.splitTimelineId }));
  }

  handleFollow = () => {
    const { intl, dispatch, params, tag } = this.props;
    const { id } = params;

    if (tag.get('following')) {
      if (unfollowTagModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unfollow_hashtag.message' defaultMessage='Are you sure you want to unfollow hashtag {name}?' values={{ name: <strong> #{tag.get('name')}</strong> }} />,
          confirm: intl.formatMessage(messages.unfollowHashtagConfirm),
          onConfirm: () => dispatch(unfollowHashtag(id)),
        }));
      } else {
        dispatch(unfollowHashtag(id));
      }
    } else {
      if (followTagModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.follow_hashtag.message' defaultMessage='Are you sure you want to follow hashtag {name}?' values={{ name: <strong>#{tag.get('name')}</strong> }} />,
          confirm: intl.formatMessage(messages.followHashtagConfirm),
          onConfirm: () => dispatch(followHashtag(id)),
        }));
      } else {
        dispatch(followHashtag(id));
      }
    }
  }

  handleToggleComposer = (event) => {
    const { columnId, dispatch, composerVisible, params: { id } } = this.props;
    const column = event.currentTarget.closest('.column') || this.columnNode;

    this.statusAnchor = captureVisibleStatusAnchor(column);
    dispatch(changeSetting(['portableComposerVisibility', hashtagComposerId(id, columnId)], !composerVisible));
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['hashtag', 'columnWidth'], value));
    }
  }

  renderColumn = (split) => {
    this.forwardColumnRef = split.setColumnRef;

    const { hasUnread, columnId, multiColumn, tag, columnWidth, intl, composerVisible } = this.props;
    const { id } = this.props.params;
    const pinned = !!columnId;
    const sourceTimelineId = hashtagTimelineId(id);
    const composerId = hashtagComposerId(id, columnId);
    const portableComposer = isAdministrator && composerVisible ? (
      <PortableComposer
        key={composerId}
        composerId={composerId}
        postingContext={buildHashtagTimelinePostingContext(id)}
      />
    ) : null;
    const emptyMessage = <FormattedMessage id='empty_column.hashtag' defaultMessage='There is nothing in this hashtag yet.' />;

    this.splitTimelineId = split.splitTimelineId;

    let followButton;

    if (tag) {
      const following = tag.get('following');

      followButton = (
        <button className={classNames('column-header__button', 'column-header__follow_button', { active: following })} onClick={this.handleFollow} title={intl.formatMessage(following ? messages.unfollowHashtag : messages.followHashtag)} aria-label={intl.formatMessage(following ? messages.unfollowHashtag : messages.followHashtag)} aria-pressed={following ? 'true' : 'false'}>
          <Icon id={following ? 'user-times' : 'user-plus'} fixedWidth className='column-header__icon' />
        </button>
      );
    }

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`hashtag_timeline-${columnId}`}
          timelineId={sourceTimelineId}
          onLoadMore={this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
          prepend={portableComposer}
          alwaysPrepend={!!portableComposer}
        />
      );
    } else {
      timeline = (
        <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
          <div className='timeline-split__pane timeline-split__pane--live'>
            <StatusListContainer
              timelineId={sourceTimelineId}
              dataTimelineId={sourceTimelineId}
              includePendingItems
              statusLimit={40}
              manageTimelineScrollState={false}
              trackIntersection={false}
              trackScroll={false}
              scrollKey={`hashtag_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
              prepend={portableComposer}
              alwaysPrepend={!!portableComposer}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`hashtag_timeline-${columnId}`}
              onLoadMore={this.handleLoadMoreHistory}
              timelineId={sourceTimelineId}
              dataTimelineId={split.splitTimelineId}
              trackIntersection
              emptyMessage={emptyMessage}
              bindToDocument={false}
            />
          </div>
        </div>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.bindColumn} label={`#${id}`} columnWidth={columnWidth}>
        <ColumnHeader
          icon='hashtag'
          active={hasUnread}
          title={this.title()}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={(
            <Fragment>
              {split.splitButton}
              <PortableComposerToggle visible={composerVisible} onToggle={this.handleToggleComposer} />
              {followButton}
              {split.closeLiveButton}
            </Fragment>
          )}
          showBackButton
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          {columnId && <ColumnSettingsContainer columnId={columnId} />}
        </ColumnHeader>

        {timeline}
      </Column>
    );
  }

  render () {
    const { columnId, multiColumn, splitRatio, location } = this.props;
    const { id, tags } = this.props.params;
    const sourceTimelineId = hashtagTimelineId(id);

    return (
      <StatusTimelineSplitController
        key={sourceTimelineId}
        sourceTimelineId={sourceTimelineId}
        splitContextKey={hashtagSplitContextKey(id, tags)}
        columnId={columnId}
        multiColumn={multiColumn}
        location={location}
        splitRatio={splitRatio}
        onSplitRatioCommit={this.handleSplitRatioCommit}
        unavailableMessage={messages.splitUnavailable}
      >
        {this.renderColumn}
      </StatusTimelineSplitController>
    );
  }

}

export default injectIntl(connect(mapStateToProps)(HashtagTimeline));
