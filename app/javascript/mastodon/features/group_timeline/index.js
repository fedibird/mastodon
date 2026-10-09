import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import classNames from 'classnames';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import Icon from '../../components/icon';
import { fetchAccount } from '../../actions/accounts';
import { makeGetAccount } from 'mastodon/selectors';
import { expandGroupTimeline, clearTimelineSplitReturnAnchor } from '../../actions/timelines';
import { groupTimelineId } from '../../actions/timeline_ids';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import GroupDetail from './components/group_detail';
import { connectGroupStream } from '../../actions/streaming';
import { defaultColumnWidth, isAdministrator } from 'mastodon/initial_state';
import PortableComposer from '../compose/portable_composer';
import PortableComposerToggle from '../compose/components/portable_composer_toggle';
import { captureVisibleStatusAnchor, columnNodeFromRef, scheduleStatusAnchorRestore } from '../compose/components/portable_composer_scroll';
import { selectPortableComposerVisible } from 'mastodon/selectors/composer';
import { applyComposerSurface } from '../../actions/composer';
import { fetchPostingContext } from '../../actions/posting_contexts';
import { selectPostingContextForAccount } from '../../selectors/posting_contexts';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { DEFAULT_TIMELINE_SPLIT_RATIO } from 'mastodon/components/timeline_splitter';
import StatusTimelineSplitController, { clampTimelineSplitRatio } from '../ui/components/status_timeline_split_controller';

const messages = defineMessages({
  title: { id: 'column.group', defaultMessage: 'Group timeline' },
  show_group_detail: { id: 'home.show_group_detail', defaultMessage: 'Show group detail' },
  hide_group_detail: { id: 'home.hide_group_detail', defaultMessage: 'Hide group detail' },
  splitUnavailable: { id: 'timeline.split_source_unavailable', defaultMessage: 'This timeline is already split in another column' },
});

const groupComposerId = (id, columnId) => (
  columnId ? `portable:group-column:${columnId}` : `portable:group-route:${id}`
);

const makeMapStateToProps = () => {
  const getAccount = makeGetAccount();

  const mapStateToProps = (state, { columnId, params: { id, tagged } }) => {
    const columns = state.getIn(['settings', 'columns']);
    const index = columns ? columns.findIndex(column => column.get('uuid') === columnId) : -1;
    const onlyMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'group', 'other', 'onlyMedia']);
    const withoutMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'group', 'other', 'withoutMedia']);
    const sourceTimelineId = groupTimelineId(id, { withoutMedia, onlyMedia, tagged });
    const timelineState = state.getIn(['timelines', sourceTimelineId]);
    const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'group', 'columnWidth']);
    const account = getAccount(state, id);

    return {
      hasUnread: !!timelineState && timelineState.get('unread') > 0,
      onlyMedia,
      withoutMedia,
      account,
      postingContext: selectPostingContextForAccount(state, id),
      columnWidth: columnWidth ?? defaultColumnWidth,
      splitRatio: clampTimelineSplitRatio(state.getIn(['settings', 'group', 'splitRatio'], DEFAULT_TIMELINE_SPLIT_RATIO)),
      composerVisible: selectPortableComposerVisible(state, groupComposerId(id, columnId)),
    };
  };

  return mapStateToProps;
};

export default @connect(makeMapStateToProps)
@injectIntl
class GroupTimeline extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static defaultProps = {
    onlyMedia: false,
    withoutMedia: false,
  };

  static propTypes = {
    account: ImmutablePropTypes.map.isRequired,
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    columnId: PropTypes.string,
    intl: PropTypes.object.isRequired,
    hasUnread: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    onlyMedia: PropTypes.bool,
    withoutMedia: PropTypes.bool,
    postingContext: PropTypes.object,
    composerVisible: PropTypes.bool,
    splitRatio: PropTypes.number,
    location: PropTypes.shape({
      key: PropTypes.string,
    }),
  };

  state = {
    collapsed: false,
    animating: false,
  };

  handlePin = () => {
    const { columnId, dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('GROUP', { id: id, other: { onlyMedia, withoutMedia, tagged } }));
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleSplitRatioCommit = (ratio) => {
    this.props.dispatch(changeSetting(['group', 'splitRatio'], ratio));
  }

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia, composerVisible, params: { id, tagged } } = this.props;

    dispatch(fetchAccount(id));

    if (isAdministrator && composerVisible) {
      dispatch(fetchPostingContext(id));
    }

    dispatch(expandGroupTimeline(id, { onlyMedia, withoutMedia, tagged }));
    this.disconnect = dispatch(connectGroupStream(id, { onlyMedia, withoutMedia, tagged }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, onlyMedia, withoutMedia, composerVisible, postingContext, columnId, params: { id, tagged } } = this.props;
    const idChanged = prevProps.params.id !== id;

    this.restoreComposerScroll(prevProps, idChanged);

    if (idChanged) {
      dispatch(fetchAccount(id));

      if (isAdministrator && composerVisible) {
        dispatch(fetchPostingContext(id));
      }
    } else if (isAdministrator && composerVisible && !prevProps.composerVisible && !postingContext) {
      dispatch(fetchPostingContext(id));
    }

    if (isAdministrator && (idChanged || (prevProps.postingContext && !postingContext))) {
      dispatch(applyComposerSurface(groupComposerId(id, columnId), { kind: 'group', key: String(id) }, postingContext, id));
    }

    const mediaChanged = prevProps.onlyMedia !== onlyMedia || prevProps.withoutMedia !== withoutMedia;
    const routeChanged = idChanged || prevProps.params.tagged !== tagged;

    if (routeChanged || mediaChanged) {
      this.disconnect();
      dispatch(expandGroupTimeline(id, { onlyMedia, withoutMedia, tagged }));
      this.disconnect = dispatch(connectGroupStream(id, { onlyMedia, withoutMedia, tagged }));
    }

    if (mediaChanged && !routeChanged) {
      dispatch(clearTimelineSplitReturnAnchor(groupTimelineId(prevProps.params.id, {
        onlyMedia: prevProps.onlyMedia,
        withoutMedia: prevProps.withoutMedia,
        tagged: prevProps.params.tagged,
      })));
    }
  }

  componentWillUnmount () {
    if (this.cancelStatusAnchor) {
      this.cancelStatusAnchor();
      this.cancelStatusAnchor = null;
    }

    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }
  }

  bindColumn = (column) => {
    this.columnNode = columnNodeFromRef(column);

    if (this.forwardColumnRef) {
      this.forwardColumnRef(column);
    }
  }

  composerIsMounted = (props) => isAdministrator && props.composerVisible && props.postingContext

  restoreComposerScroll = (prevProps, idChanged) => {
    if (idChanged) {
      this.statusAnchor = null;
      return;
    }

    if (this.composerIsMounted(prevProps) === this.composerIsMounted(this.props)) {
      return;
    }

    if (this.cancelStatusAnchor) {
      this.cancelStatusAnchor();
    }

    this.cancelStatusAnchor = scheduleStatusAnchorRestore(this.statusAnchor);
    this.statusAnchor = null;
  }

  handleLoadMore = maxId => {
    const { dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    dispatch(expandGroupTimeline(id, { maxId, onlyMedia, withoutMedia, tagged }));
  }

  handleLoadMoreHistory = maxId => {
    const { dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    dispatch(expandGroupTimeline(id, { maxId, onlyMedia, withoutMedia, tagged, timelineId: this.splitTimelineId }));
  }

  handleToggleClick = (e) => {
    e.stopPropagation();
    this.setState({ collapsed: !this.state.collapsed, animating: true });
  }

  handleTransitionEnd = () => {
    this.setState({ animating: false });
  }

  handleToggleComposer = (event) => {
    const { columnId, dispatch, composerVisible, params: { id } } = this.props;
    const column = event.currentTarget.closest('.column') || this.columnNode;

    this.statusAnchor = captureVisibleStatusAnchor(column);
    dispatch(changeSetting(['portableComposerVisibility', groupComposerId(id, columnId)], !composerVisible));
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['group', 'columnWidth'], value));
    }
  }

  renderColumn = (split) => {
    this.forwardColumnRef = split.setColumnRef;

    const { intl, hasUnread, columnId, multiColumn, onlyMedia, withoutMedia, params: { id, tagged }, account, columnWidth, postingContext, composerVisible } = this.props;
    const pinned = !!columnId;
    const { collapsed, animating } = this.state;
    const sourceTimelineId = groupTimelineId(id, { withoutMedia, onlyMedia, tagged });
    const composerId = groupComposerId(id, columnId);
    const portableComposer = isAdministrator && composerVisible && postingContext ? (
      <PortableComposer
        key={composerId}
        composerId={composerId}
        surface={{ kind: 'group', key: String(id) }}
        postingContext={postingContext}
        postingContextAccountId={id}
      />
    ) : null;
    const emptyMessage = <FormattedMessage id='empty_column.group' defaultMessage='The group timeline is empty. When members of this group post new toots, they will appear here.' />;

    this.splitTimelineId = split.splitTimelineId;

    const collapsibleClassName = classNames('column-header__collapsible', {
      'collapsed': collapsed,
      'animating': animating,
    });

    const collapsibleButtonClassName = classNames('column-header__button', {
      'active': !collapsed,
    });

    const groupDetailButton = (
      <button
        className={collapsibleButtonClassName}
        title={intl.formatMessage(collapsed ? messages.hide_group_detail : messages.show_group_detail)}
        aria-label={intl.formatMessage(collapsed ? messages.hide_group_detail : messages.show_group_detail)}
        aria-pressed={collapsed ? 'false' : 'true'}
        onClick={this.handleToggleClick}
      >
        <Icon id='info-circle' />
      </button>
    );

    const displayName = account.get('display_name');
    const title = displayName.length === 0 ? account.get('acct').split('@')[0] : displayName;

    const groupDetail = (
      <div className={collapsibleClassName} tabIndex={collapsed ? -1 : null} onTransitionEnd={this.handleTransitionEnd}>
        {(!collapsed || animating) && <><GroupDetail id={id} /></>}
      </div>
    );

    let timeline;

    if (!split.isSplit) {
      timeline = (
        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`group_timeline-${columnId}`}
          timelineId={sourceTimelineId}
          onLoadMore={this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
          showCard={!withoutMedia}
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
              scrollKey={`group_timeline-${columnId}-live`}
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
              prepend={portableComposer}
              alwaysPrepend={!!portableComposer}
            />
          </div>

          {split.splitter}

          <div className='timeline-split__pane timeline-split__pane--history'>
            <StatusListContainer
              trackScroll={multiColumn ? !pinned : false}
              scrollKey={`group_timeline-${columnId}`}
              onLoadMore={this.handleLoadMoreHistory}
              timelineId={sourceTimelineId}
              dataTimelineId={split.splitTimelineId}
              trackIntersection
              emptyMessage={emptyMessage}
              bindToDocument={false}
              showCard={!withoutMedia}
            />
          </div>
        </div>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.bindColumn} label={title} columnWidth={columnWidth}>
        <ColumnHeader
          icon='users'
          active={hasUnread}
          title={title}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={split.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={(
            <Fragment>
              {split.splitButton}
              <PortableComposerToggle visible={composerVisible} onToggle={this.handleToggleComposer} />
              {groupDetailButton}
              {split.closeLiveButton}
            </Fragment>
          )}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <ColumnSettingsContainer columnId={columnId} />
        </ColumnHeader>

        {groupDetail}

        {timeline}
      </Column>
    );
  }

  render () {
    const { account, columnId, multiColumn, onlyMedia, withoutMedia, params: { id, tagged }, splitRatio, location } = this.props;

    if (!account) {
      return <div />;
    }

    const sourceTimelineId = groupTimelineId(id, { withoutMedia, onlyMedia, tagged });

    return (
      <StatusTimelineSplitController
        key={sourceTimelineId}
        sourceTimelineId={sourceTimelineId}
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
