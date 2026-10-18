import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { defineMessages, FormattedMessage } from 'react-intl';

import StatusList from '../../../components/status_list';
import { accountContextHostId } from '../../../timeline_seek/account_context';
import { pageAccountContext, settleAccountContextView } from '../../../actions/account_context_view';
import { accountContextSession } from '../../../reducers/account_context_views';

const messages = defineMessages({
  empty: { id: 'account_context.empty', defaultMessage: 'No posts around this one are loaded.' },
  seeking: { id: 'account_context.seeking', defaultMessage: 'Loading posts around this one…' },
  not_in_source: { id: 'account_context.not_in_source', defaultMessage: 'This post is not in that account’s posts. The previous posts were kept.' },
  not_visible: { id: 'account_context.not_visible', defaultMessage: 'This post cannot be shown. The previous posts were kept.' },
  not_found: { id: 'account_context.not_found', defaultMessage: 'This post was not found. The previous posts were kept.' },
  unavailable: { id: 'account_context.unavailable', defaultMessage: 'These posts are unavailable. The previous posts were kept.' },
  unknown: { id: 'account_context.unknown', defaultMessage: 'These posts could not be opened. The previous posts were kept.' },
  unsupported: { id: 'account_context.unsupported', defaultMessage: 'These posts could not be opened. The previous posts were kept.' },
  filtered: { id: 'account_context.filtered', defaultMessage: 'This post is filtered. The previous posts were kept.' },
  not_loaded: { id: 'account_context.not_loaded', defaultMessage: 'This post was not on screen yet. The previous posts were kept.' },
  cancelled: { id: 'account_context.cancelled', defaultMessage: 'Loading was cancelled. The previous posts were kept.' },
  stale: { id: 'account_context.stale', defaultMessage: 'This view changed before the posts arrived.' },
});

const makeMapStateToProps = () => {
  const mapStateToProps = (state, { hostKey }) => {
    const timelineId = accountContextHostId(hostKey);
    const timeline = timelineId ? state.getIn(['timelines', timelineId]) : null;
    const session = accountContextSession(state, hostKey);
    const seek = timeline && timeline.get('seek');
    const history = timeline && timeline.get('window');
    const revision = history ? (history.get('revision') || 0) : 0;
    const pending = !!(
      seek
      && seek.get('phase') === 'resolved'
      && seek.get('scrollStatus') === 'pending'
      && seek.get('scrollRevision') === revision
      && seek.get('anchorId')
      && session
      && session.get('sourceKey')
      && seek.get('source') === session.get('sourceKey')
    );

    return {
      timelineId,
      session,
      statusIds: timeline ? timeline.get('items', ImmutableList()) : ImmutableList(),
      isLoading: !!(timeline && timeline.get('isLoading')) || !!(session && session.get('phase') === 'seeking') || !!(seek && seek.get('phase') === 'pending'),
      hasMore: !!(history && history.get('hasOlder')),
      hasNewer: !!(history && history.get('hasNewer')),
      newerLoading: history ? history.getIn(['newer', 'status']) === 'loading' : false,
      newerStatus: history ? history.getIn(['newer', 'status']) : null,
      olderStatus: history ? history.getIn(['older', 'status']) : null,
      windowRevision: revision,
      anchorResolution: history ? history.get('anchorResolution') : null,
      historyUnbounded: !!(history && history.get('unbounded')),
      seekScrollPending: pending,
      seekSessionId: pending ? seek.get('id') : null,
      seekAnchorId: pending ? seek.get('anchorId') : null,
      seekScrollRevision: pending ? revision : 0,
      contextSource: timeline ? timeline.get('contextSource') : null,
    };
  };

  return mapStateToProps;
};

class AccountContextTimeline extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    hostKey: PropTypes.string.isRequired,
    timelineId: PropTypes.string,
    session: ImmutablePropTypes.map,
    statusIds: ImmutablePropTypes.list.isRequired,
    isLoading: PropTypes.bool,
    hasMore: PropTypes.bool,
    hasNewer: PropTypes.bool,
    newerLoading: PropTypes.bool,
    newerStatus: PropTypes.string,
    olderStatus: PropTypes.string,
    windowRevision: PropTypes.number,
    anchorResolution: PropTypes.string,
    historyUnbounded: PropTypes.bool,
    seekScrollPending: PropTypes.bool,
    seekSessionId: PropTypes.string,
    seekAnchorId: PropTypes.string,
    seekScrollRevision: PropTypes.number,
    contextSource: PropTypes.string,
  };

  handleLoadOlder = () => {
    const { dispatch, hostKey, session, contextSource } = this.props;

    if (!session || session.get('sourceKey') !== contextSource) {
      return;
    }

    dispatch(pageAccountContext({ hostTimelineId: hostKey, direction: 'older' }));
  };

  handleLoadNewer = () => {
    const { dispatch, hostKey, session, contextSource } = this.props;

    if (!session || session.get('sourceKey') !== contextSource) {
      return;
    }

    dispatch(pageAccountContext({ hostTimelineId: hostKey, direction: 'newer' }));
  };

  handleSeekScroll = ({ sessionId, revision, anchorId, scrolled }) => {
    const { dispatch, hostKey, session, statusIds, contextSource } = this.props;
    const article = this.node ? this.node.querySelector(`article[data-id="${anchorId}"]`) : null;

    if (!session || (contextSource && session.get('sourceKey') !== contextSource)) {
      return;
    }

    dispatch(settleAccountContextView({
      hostTimelineId: hostKey,
      renderedIds: statusIds,
      articlePresent: scrolled ? true : !!article,
      sessionId,
      scrollRevision: revision,
      source: session.get('sourceKey'),
    }));
  };

  setRef = (node) => {
    this.node = node;
  };

  render () {
    const { hostKey, session, statusIds, isLoading } = this.props;
    const noticeKey = session && session.get('notice');
    const notice = noticeKey && (messages[noticeKey] || messages.unknown);
    const showSpinner = isLoading && statusIds.size === 0;

    return (
      <div className='account-context-timeline' ref={this.setRef}>
        {notice && (
          <p className='account-context-timeline__notice' role='status'>
            <FormattedMessage {...notice} />
          </p>
        )}
        {showSpinner && (
          <p className='account-context-timeline__notice' role='status'>
            <FormattedMessage {...messages.seeking} />
          </p>
        )}
        <StatusList
          scrollKey={`account-context-${hostKey}`}
          statusIds={statusIds}
          isLoading={isLoading}
          hasMore={this.props.hasMore}
          hasNewer={this.props.hasNewer}
          onLoadMore={this.handleLoadOlder}
          onLoadNewer={this.handleLoadNewer}
          newerLoading={this.props.newerLoading}
          newerStatus={this.props.newerStatus}
          olderStatus={this.props.olderStatus}
          windowedHistory
          windowRevision={this.props.windowRevision}
          anchorResolution={this.props.anchorResolution}
          historyUnbounded={this.props.historyUnbounded}
          seekScrollPending={this.props.seekScrollPending}
          seekSessionId={this.props.seekSessionId}
          seekAnchorId={this.props.seekAnchorId}
          seekScrollRevision={this.props.seekScrollRevision}
          onSeekScroll={this.handleSeekScroll}
          trackScroll={false}
          trackIntersection={false}
          bindToDocument={false}
          emptyMessage={<FormattedMessage {...messages.empty} />}
          timelineId={`account-context:${hostKey}`}
        />
      </div>
    );
  }

}

export default connect(makeMapStateToProps)(AccountContextTimeline);
