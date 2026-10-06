import React from 'react';
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
import { expandGroupTimeline } from '../../actions/timelines';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import ColumnSettingsContainer from './containers/column_settings_container';
import GroupDetail from './components/group_detail';
import { connectGroupStream } from '../../actions/streaming';
import { defaultColumnWidth, new_features_policy } from 'mastodon/initial_state';
import PortableComposer from '../compose/portable_composer';
import { fetchPostingContext } from '../../actions/posting_contexts';
import { selectPostingContextForAccount } from '../../selectors/posting_contexts';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  title: { id: 'column.group', defaultMessage: 'Group timeline' },
  show_group_detail: { id: 'home.show_group_detail', defaultMessage: 'Show group detail' },
  hide_group_detail: { id: 'home.hide_group_detail', defaultMessage: 'Hide group detail' },
});

const makeMapStateToProps = () => {
  const getAccount = makeGetAccount();

  const mapStateToProps = (state, { columnId, params: { id, tagged } }) => {
    const uuid = columnId;
    const columns = state.getIn(['settings', 'columns']);
    const index = columns.findIndex(c => c.get('uuid') === uuid);
    const onlyMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'onlyMedia']) : state.getIn(['settings', 'group', 'other', 'onlyMedia']);
    const withoutMedia = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'other', 'withoutMedia']) : state.getIn(['settings', 'group', 'other', 'withoutMedia']);
    const timelineState = state.getIn(['timelines', `group:${id}${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}${tagged ? `:${tagged}` : ''}`]);
    const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'group', 'columnWidth']);
    const account = getAccount(state, id);

    return {
      hasUnread: !!timelineState && timelineState.get('unread') > 0,
      onlyMedia,
      withoutMedia,
      account,
      postingContext: selectPostingContextForAccount(state, id),
      columnWidth: columnWidth ?? defaultColumnWidth,
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

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  componentDidMount () {
    const { dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    dispatch(fetchAccount(id));

    if (new_features_policy === 'tester') {
      dispatch(fetchPostingContext(id));
    }

    dispatch(expandGroupTimeline(id, { onlyMedia, withoutMedia, tagged }));
    this.disconnect = dispatch(connectGroupStream(id, { onlyMedia, withoutMedia, tagged }));
  }

  componentDidUpdate (prevProps) {
    const { dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    if (prevProps.params.id !== id) {
      dispatch(fetchAccount(id));

      if (new_features_policy === 'tester') {
        dispatch(fetchPostingContext(id));
      }
    }

    if (prevProps.params.id !== id || prevProps.onlyMedia !== onlyMedia || prevProps.withoutMedia !== this.props.withoutMedia || prevProps.tagged !== tagged) {
      this.disconnect();
      dispatch(expandGroupTimeline(id, { onlyMedia, withoutMedia, tagged }));
      this.disconnect = dispatch(connectGroupStream(id, { onlyMedia, withoutMedia, tagged }));
    }
  }

  componentWillUnmount () {
    if (this.disconnect) {
      this.disconnect();
      this.disconnect = null;
    }
  }

  setRef = c => {
    this.column = c;
  }

  handleLoadMore = maxId => {
    const { dispatch, onlyMedia, withoutMedia, params: { id, tagged } } = this.props;

    dispatch(expandGroupTimeline(id, { maxId, onlyMedia, withoutMedia, tagged }));
  }

  handleToggleClick = (e) => {
    e.stopPropagation();
    this.setState({ collapsed: !this.state.collapsed, animating: true });
  }

  handleTransitionEnd = () => {
    this.setState({ animating: false });
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['group', 'columnWidth'], value));
    }
  }

  render () {
    const { intl, hasUnread, columnId, multiColumn, onlyMedia, withoutMedia, params: { id, tagged }, account, columnWidth, postingContext } = this.props;
    const pinned = !!columnId;

    const { collapsed, animating } = this.state;

    if (!account) {
      return <div />;
    }

    const composerId = columnId ? `portable:group-column:${columnId}` : `portable:group-route:${id}`;
    const portableComposer = new_features_policy === 'tester' && postingContext ? (
      <PortableComposer
        key={composerId}
        composerId={composerId}
        postingContext={postingContext}
      />
    ) : null;

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

    const displayName = account.get('display_name')
    const title = displayName.length === 0 ? account.get('acct').split('@')[0] : displayName

    const groupDetail = (
      <div className={collapsibleClassName} tabIndex={collapsed ? -1 : null} onTransitionEnd={this.handleTransitionEnd}>
        {(!collapsed || animating) && <><GroupDetail id={id} /></>}
      </div>
    );

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={title} columnWidth={columnWidth}>
        <ColumnHeader
          icon='users'
          active={hasUnread}
          title={title}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={groupDetailButton}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <ColumnSettingsContainer columnId={columnId} />
        </ColumnHeader>

        {groupDetail}

        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`group_timeline-${columnId}`}
          timelineId={`group:${id}${withoutMedia ? ':nomedia' : ''}${onlyMedia ? ':media' : ''}${tagged ? `:${tagged}` : ''}`}
          onLoadMore={this.handleLoadMore}
          emptyMessage={<FormattedMessage id='empty_column.group' defaultMessage='The group timeline is empty. When members of this group post new toots, they will appear here.' />}
          bindToDocument={!multiColumn}
          showCard={!withoutMedia}
          prepend={portableComposer}
          alwaysPrepend={!!portableComposer}
        />
      </Column>
    );
  }

}
