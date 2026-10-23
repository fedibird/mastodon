import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { FormattedMessage, injectIntl } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import ImmutablePropTypes from 'react-immutable-proptypes';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import Icon from '../../components/icon';
import StatusList from '../../components/status_list';
import { addColumn, changeColumnParams, moveColumn, removeColumn } from '../../actions/columns';
import { changeSetting } from '../../actions/settings';
import { clearMixSplitAnchor, closeMixTimeline, createMixSplit, destroyMixSplit, loadMixTimeline, mixColumnKey, retryMixSource, saveMixSplitAnchor } from '../../actions/mix_timelines';
import { closeMixStream, openMixStream, pinMixStream, reconcileMixSource, revealMixStream } from '../../actions/mix_streaming';
import TimelineSplitControllerCore from '../ui/components/timeline_split_controller_core';
import { defaultColumnWidth, me } from 'mastodon/initial_state';
import { plainMix } from 'mastodon/mix/definition';
import { sourceKey } from 'mastodon/mix/source';
import { badgeRevisionToken, mixBadgeIdentity, paneBadgeToken, sourceBadges, storeBadge } from 'mastodon/mix/source_badges';
import { mixTimelineView } from 'mastodon/mix/view';
import { consumeMixInfoFlag, mixInfoStartsOpen } from './info_state';
import MixInfoPanel from './components/info_panel';
import messages from './messages';

const findMix = (state, id) => {
  if (!id) {
    return null;
  }

  return state.getIn(['settings', 'mixes'], ImmutableList()).find(item => item && item.get('id') === String(id)) || null;
};

const mixSignature = (mix) => {
  const plain = plainMix(mix);

  if (!plain) {
    return '';
  }

  return plain.sources.map(source => sourceKey(source)).filter(Boolean).join('\n');
};

const mapStateToProps = (state, { columnId, params }) => {
  const mixId = params && params.id ? String(params.id) : null;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns && columnId ? columns.findIndex(column => column.get('uuid') === columnId) : -1;
  const columnWidth = index >= 0 ? columns.get(index).getIn(['params', 'columnWidth']) : null;
  const mix = findMix(state, mixId);
  const columnKey = mixColumnKey(columnId, mixId);
  const timeline = state.getIn(['mix_timelines', columnKey]);

  return {
    mixId,
    mix,
    signature: mixSignature(mix),
    columnKey,
    view: mixTimelineView(timeline, state.get('statuses'), state.get('filters'), me, undefined, state.get('filterMatches')),
    liveView: timeline && timeline.get('split') ? mixTimelineView(timeline, state.get('statuses'), state.get('filters'), me, 'live', state.get('filterMatches')) : null,
    historyView: timeline && timeline.get('split') ? mixTimelineView(timeline, state.get('statuses'), state.get('filters'), me, 'history', state.get('filterMatches')) : null,
    splitId: timeline ? timeline.getIn(['split', 'id']) : null,
    splitReturnAnchor: state.getIn(['mix_timelines', '__anchors', columnKey]) || null,
    splitRatio: state.getIn(['settings', 'mixTimeline', 'splitRatio'], 35),
    columnWidth: columnWidth || defaultColumnWidth,
    lists: state.get('lists'),
    accounts: state.get('accounts'),
  };
};

export const mixTimelineMode = ({ mix }) => {
  if (!mix) {
    return 'deleted';
  }

  return 'ready';
};

export class MixTimelinePage extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    params: PropTypes.object,
    columnId: PropTypes.string,
    mixId: PropTypes.string,
    mix: PropTypes.object,
    signature: PropTypes.string,
    columnKey: PropTypes.string,
    liveView: PropTypes.object,
    historyView: PropTypes.object,
    splitId: PropTypes.string,
    splitReturnAnchor: PropTypes.object,
    splitRatio: PropTypes.number,
    location: PropTypes.object,
    view: PropTypes.shape({
      statusIds: ImmutablePropTypes.list,
      reconciliationIds: ImmutablePropTypes.list,
      contextById: PropTypes.object,
      warningsById: PropTypes.object,
      orderGuaranteed: PropTypes.bool,
      waiting: PropTypes.bool,
      hasMore: PropTypes.bool,
      running: PropTypes.bool,
      suspended: PropTypes.array,
      errors: PropTypes.array,
      pendingCount: PropTypes.number,
      degraded: PropTypes.array,
      offline: PropTypes.array,
      incomplete: PropTypes.array,
      restOnly: PropTypes.array,
    }),
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    lists: PropTypes.object,
    accounts: PropTypes.object,
    history: PropTypes.shape({
      replace: PropTypes.func,
    }),
  };

  static contextTypes = {
    router: PropTypes.object,
  };

  state = {
    infoOpen: mixInfoStartsOpen(this.props.location),
  };

  emptyBadges = [];

  badgeCache = new Map();

  badgesForSingle = (id) => this.lookupBadges('single', id);

  badgesForLive = (id) => this.lookupBadges('live', id);

  badgesForHistory = (id) => this.lookupBadges('history', id);

  viewForPane (pane) {
    if (pane === 'live') {
      return this.props.liveView;
    }

    if (pane === 'history') {
      return this.props.historyView;
    }

    return this.props.view;
  }

  badgeIdentity () {
    const plain = plainMix(this.props.mix);

    return mixBadgeIdentity({
      sources: plain ? plain.sources : [],
      lists: this.props.lists,
      accounts: this.props.accounts,
      locale: this.props.intl && this.props.intl.locale,
    });
  }

  lookupBadges (pane, id) {
    const view = this.viewForPane(pane);
    const keys = view && view.sourceKeysById && view.sourceKeysById[id];

    if (!this.props.mix || !keys || !keys.length) {
      return this.emptyBadges;
    }

    const warnings = (view.sourceWarningsById && view.sourceWarningsById[id]) || {};
    const identity = this.badgeIdentity();
    const token = paneBadgeToken({ pane, keys, warnings, identity });
    const cacheKey = `${pane}:${id}`;
    const hit = this.badgeCache.get(cacheKey);

    if (hit && hit.token === token) {
      return hit.value;
    }

    const plain = plainMix(this.props.mix);
    const value = sourceBadges(plain ? plain.sources : [], keys, {
      formatMessage: (message, values) => this.props.intl.formatMessage(message, values),
      lists: this.props.lists,
      accounts: this.props.accounts,
      warningsByKey: warnings,
    });

    return storeBadge(this.badgeCache, cacheKey, { token, value });
  }

  badgeRevision () {
    return badgeRevisionToken({
      views: [this.props.view, this.props.liveView, this.props.historyView],
      identity: this.badgeIdentity(),
    });
  }

  routerHistory = () => {
    if (this.props.history) {
      return this.props.history;
    }

    return this.context.router && this.context.router.history;
  };

  componentDidMount () {
    this.loadTimeline();

    if (this.state.infoOpen) {
      consumeMixInfoFlag(this.routerHistory(), this.props.location);
    }
  }

  componentDidUpdate (prevProps) {
    if (prevProps.mixId !== this.props.mixId) {
      const infoOpen = mixInfoStartsOpen(this.props.location);

      if (infoOpen !== this.state.infoOpen) {
        this.setState({ infoOpen });
      }

      if (infoOpen) {
        consumeMixInfoFlag(this.routerHistory(), this.props.location);
      }
    }

    if (prevProps.columnKey && prevProps.columnKey !== this.props.columnKey) {
      this.props.dispatch(closeMixStream(prevProps.columnKey));
      this.props.dispatch(closeMixTimeline(prevProps.columnKey));
    }

    if (!this.props.mix && prevProps.mix && prevProps.columnKey) {
      this.props.dispatch(closeMixStream(prevProps.columnKey));
      this.props.dispatch(closeMixTimeline(prevProps.columnKey));
      return;
    }

    if (prevProps.columnKey !== this.props.columnKey || prevProps.signature !== this.props.signature) {
      this.loadTimeline();
    }
  }

  componentWillUnmount () {
    if (this.props.columnKey) {
      this.props.dispatch(closeMixStream(this.props.columnKey));
      this.props.dispatch(closeMixTimeline(this.props.columnKey));
    }
  }

  loadTimeline () {
    if (this.props.mix && this.props.columnKey) {
      this.props.dispatch(loadMixTimeline(this.props.columnKey, this.props.mix));
      this.props.dispatch(openMixStream(this.props.columnKey, this.props.mix));
    }
  }

  handleLoadMore = () => {
    this.props.dispatch(loadMixTimeline(this.props.columnKey, this.props.mix, { extend: true }));
  };

  handleLoadHistory = () => {
    this.props.dispatch(loadMixTimeline(this.props.columnKey, this.props.mix, {
      extend: true,
      scope: 'history',
      splitId: this.props.splitId,
    }));
  };

  handleCreateSplit = (splitId) => {
    this.props.dispatch(createMixSplit(this.props.columnKey, splitId));
  };

  handleDestroySplit = (splitId, options) => {
    this.props.dispatch(destroyMixSplit(this.props.columnKey, splitId, options || {}));
  };

  handleSplitRatio = (ratio) => {
    this.props.dispatch(changeSetting(['mixTimeline', 'splitRatio'], ratio));
  };

  handleSaveAnchor = (anchor) => {
    this.props.dispatch(saveMixSplitAnchor(this.props.columnKey, anchor));
  };

  handleClearAnchor = () => {
    this.props.dispatch(clearMixSplitAnchor(this.props.columnKey));
  };

  handleScrollToTop = () => {
    this.props.dispatch(pinMixStream(this.props.columnKey, true));
  };

  handleScroll = () => {
    this.props.dispatch(pinMixStream(this.props.columnKey, false));
  };

  handleReveal = () => {
    this.props.dispatch(revealMixStream(this.props.columnKey));
  };

  handleRefreshRest = (event) => {
    const sourceKey = event.currentTarget.getAttribute('data-source-key');

    if (sourceKey) {
      this.props.dispatch(reconcileMixSource(this.props.columnKey, sourceKey));
    }
  };

  handleRetry = (event) => {
    const sourceKey = event.currentTarget.getAttribute('data-source-key');
    const scope = event.currentTarget.getAttribute('data-scope');

    if (!sourceKey) {
      return;
    }

    if (scope === 'history') {
      this.props.dispatch(retryMixSource(this.props.columnKey, this.props.mix, sourceKey, {
        scope: 'history',
        splitId: this.props.splitId,
      }));
      return;
    }

    this.props.dispatch(retryMixSource(this.props.columnKey, this.props.mix, sourceKey));
  };

  contextTypeFor = (view) => (id) => {
    const contexts = view && view.contextById;

    return contexts ? contexts[id] : null;
  };

  warningTitlesFor = (view) => (id) => {
    const warnings = view && view.warningsById;

    return warnings && warnings[id] ? warnings[id] : [];
  };

  buildNotices = (view, pane) => {
    const { intl } = this.props;
    const notices = [];

    if (view && pane !== 'live') {
      const incomplete = view.incomplete && view.incomplete.length ? view.incomplete : (view.suspended || []);

      incomplete.forEach(item => {
        notices.push({
          key: `gap-${item.key}`,
          sourceKey: item.key,
          text: intl.formatMessage(messages.incomplete, { name: item.label || item.key }),
          retry: true,
          scope: pane === 'history' ? 'history' : null,
        });
      });

      if (!incomplete.length && !view.orderGuaranteed && !view.waiting && (pane === 'history' || (view.errors && view.errors.length))) {
        notices.push({ key: 'order', text: intl.formatMessage(messages.orderPartial) });
      }

      (view.errors || []).forEach(item => {
        const name = item.label || item.key;
        let message = messages.sourceUnavailable;

        if (item.error === 'forbidden') {
          message = messages.sourceForbidden;
        } else if (item.error === 'not_found') {
          message = messages.sourceMissing;
        }

        const rateLimited = item.error === 'rate_limit' && item.retryAt && item.retryAt > Date.now();

        notices.push({
          key: `error-${item.key}`,
          sourceKey: item.key,
          text: intl.formatMessage(message, { name }),
          retry: item.error === 'server' || (item.error === 'rate_limit' && !rateLimited),
          scope: pane === 'history' ? 'history' : null,
        });
      });
    }

    if (pane === 'history') {
      return notices;
    }

    if (pane !== 'live' && view && view.pendingCount) {
      notices.push({
        key: 'pending',
        text: intl.formatMessage(messages.pendingPosts, { count: view.pendingCount }),
        reveal: true,
      });
    }

    if (view && view.restOnly && view.restOnly.length) {
      view.restOnly.forEach(item => {
        notices.push({
          key: `rest-${item.key}`,
          text: intl.formatMessage(messages.restOnly, { name: item.label || item.key }),
          refresh: item.key,
        });
      });
    }

    if (view && view.offline && view.offline.length) {
      view.offline.forEach(item => {
        notices.push({
          key: `offline-${item.key}`,
          text: intl.formatMessage(messages.streamOffline, { name: item.label || item.key }),
        });
      });
    }

    if (view && view.degraded && view.degraded.length) {
      view.degraded.forEach(key => {
        notices.push({
          key: `degraded-${key}`,
          text: intl.formatMessage(messages.streamDegraded, { name: key }),
        });
      });
    }

    return notices;
  };

  renderNotices = (view, pane) => this.buildNotices(view, pane).map(notice => (
    <p key={notice.key || notice.text} className='mix-editor__notice'>
      {notice.reveal ? null : (notice.text || notice)}
      {notice.retry && (
        <button type='button' className='button button-secondary' data-source-key={notice.sourceKey || notice.key} data-scope={notice.scope || undefined} onClick={this.handleRetry}>
          {this.props.intl.formatMessage(messages.retrySource, { name: notice.sourceKey || notice.key })}
        </button>
      )}
      {notice.reveal && (
        <button type='button' className='button button-secondary' onClick={this.handleReveal}>
          {notice.text}
        </button>
      )}
      {notice.refresh && (
        <button type='button' className='button button-secondary' data-source-key={notice.refresh} onClick={this.handleRefreshRest}>
          {this.props.intl.formatMessage(messages.refreshRest, { name: notice.refresh })}
        </button>
      )}
    </p>
  ));

  handlePin = () => {
    const { columnId, dispatch, mixId } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else if (mixId) {
      dispatch(addColumn('MIX', { id: mixId }));
    }
  };

  handleMove = (direction) => {
    this.props.dispatch(moveColumn(this.props.columnId, direction));
  };

  handleWidthChange = (value) => {
    if (this.props.columnId) {
      this.props.dispatch(changeColumnParams(this.props.columnId, 'columnWidth', value));
    }
  };

  setInfoButton = (node) => {
    this.infoButton = node;
  };

  handleToggleInfo = (event) => {
    event.preventDefault();
    event.stopPropagation();
    this.setState(state => ({ infoOpen: !state.infoOpen }));
  };

  handleInfoButtonKeyDown = (event) => {
    if (event.key !== 'Escape' || !this.state.infoOpen) {
      return;
    }

    event.preventDefault();
    this.setState({ infoOpen: false });
  };

  handleInfoKeyDown = (event) => {
    if (event.key !== 'Escape' || !this.state.infoOpen) {
      return;
    }

    event.preventDefault();
    this.setState({ infoOpen: false });

    if (this.infoButton) {
      this.infoButton.focus();
    }
  };

  render () {
    const { intl, columnId, mixId, mix, multiColumn, columnWidth, view, liveView, historyView } = this.props;
    const mode = mixTimelineMode({ mix });
    const plain = mode === 'ready' ? plainMix(mix) : null;
    const title = plain ? plain.title : intl.formatMessage(messages.heading);
    const statusIds = view && view.statusIds ? view.statusIds : ImmutableList();
    const noticeNodes = this.renderNotices(view, 'single');

    let body;

    if (mode === 'deleted') {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.deleted)}</p>;
    } else {
      body = (
        <StatusList
          statusIds={statusIds}
          filterStatusIds={view && view.reconciliationIds}
          bindToDocument={!multiColumn}
          scrollKey={`mix-${this.props.columnKey}`}
          hasMore={!!(view && view.hasMore)}
          isLoading={!!(view && (view.waiting || view.running))}
          onLoadMore={this.handleLoadMore}
          onScrollToTop={this.handleScrollToTop}
          onScroll={this.handleScroll}
          contextTypeForId={this.contextTypeFor(view)}
          warningTitlesForId={this.warningTitlesFor(view)}
          sourceBadgesForId={this.badgesForSingle}
          badgeRevision={this.badgeRevision()}
          emptyMessage={<FormattedMessage id='mixes.empty_timeline' defaultMessage='No posts in this mix yet.' />}
          prepend={noticeNodes.length ? <div className='mix-editor'>{noticeNodes}</div> : null}
        />
      );
    }

    const list = (ids, extra) => (
      <StatusList
        statusIds={ids}
        filterStatusIds={extra.view && extra.view.reconciliationIds}
        scrollKey={`mix-${this.props.columnKey}-${extra.key}`}
        hasMore={extra.hasMore}
        isLoading={extra.isLoading}
        onLoadMore={extra.onLoadMore}
        bindToDocument={false}
        trackScroll={false}
        trackIntersection={extra.trackIntersection}
        readingSurface={!!extra.readingSurface}
        contextTypeForId={this.contextTypeFor(extra.view)}
        warningTitlesForId={this.warningTitlesFor(extra.view)}
        sourceBadgesForId={extra.badgesFor}
        badgeRevision={this.badgeRevision()}
        emptyMessage={<FormattedMessage id='mixes.empty_timeline' defaultMessage='No posts in this mix yet.' />}
        prepend={extra.prepend}
      />
    );

    return (
      <TimelineSplitControllerCore
        intl={intl}
        sourceTimelineId={this.props.columnKey || 'mix'}
        columnId={columnId}
        multiColumn={multiColumn}
        location={this.props.location}
        splitRatio={this.props.splitRatio}
        splitContextKey={this.props.signature}
        activeSplitId={this.props.splitId}
        splitReturnAnchor={this.props.splitReturnAnchor}
        splitBlocked={!view || !!view.waiting}
        anchorHold={!!(view && view.waiting)}
        unavailableMessage={messages.splitUnavailable}
        onSplitRatioCommit={this.handleSplitRatio}
        onCreate={this.handleCreateSplit}
        onDestroy={this.handleDestroySplit}
        onSaveReturnAnchor={this.handleSaveAnchor}
        onClearReturnAnchor={this.handleClearAnchor}
      >
        {split => (
          <Column bindToDocument={!multiColumn} ref={split.setColumnRef} label={title} columnWidth={columnWidth}>
            <ColumnHeader
              icon='random'
              title={title}
              onPin={mode === 'ready' ? this.handlePin : undefined}
              onMove={this.handleMove}
              onClick={split.handleHeaderClick}
              onWidthChange={this.handleWidthChange}
              pinned={!!columnId}
              multiColumn={multiColumn}
              columnWidth={columnWidth}
              extraButton={mode === 'ready' ? (
                <React.Fragment>
                  <button
                    type='button'
                    className={classNames('column-header__button', 'mix-column__info', { active: this.state.infoOpen })}
                    title={intl.formatMessage(messages.mixInfo)}
                    aria-label={intl.formatMessage(messages.mixInfo)}
                    aria-expanded={this.state.infoOpen}
                    aria-controls={`mix-info-${this.props.columnKey || mixId || 'mix'}`}
                    onClick={this.handleToggleInfo}
                    onKeyDown={this.handleInfoButtonKeyDown}
                    ref={this.setInfoButton}
                  >
                    <Icon id='info-circle' />
                  </button>
                  {split.splitButton}
                  {split.closeLiveButton}
                </React.Fragment>
              ) : undefined}
              appendContent={mode === 'ready' && this.state.infoOpen ? (
                <MixInfoPanel
                  id={`mix-info-${this.props.columnKey || mixId || 'mix'}`}
                  intl={intl}
                  mix={mix}
                  mixId={mixId}
                  lists={this.props.lists}
                  accounts={this.props.accounts}
                  onKeyDown={this.handleInfoKeyDown}
                />
              ) : null}
              showBackButton
            />
            {mode !== 'ready' || !split.isSplit ? body : (
              <React.Fragment>
                <div className='timeline-split' style={{ '--timeline-split-ratio': split.ratio }}>
                  <div className='timeline-split__pane timeline-split__pane--live'>
                    {list(liveView ? liveView.statusIds : ImmutableList(), {
                      key: 'live',
                      view: liveView,
                      badgesFor: this.badgesForLive,
                      hasMore: false,
                      isLoading: false,
                      trackIntersection: false,
                      prepend: this.renderNotices(liveView, 'live'),
                    })}
                  </div>
                  {split.splitter}
                  <div className='timeline-split__pane timeline-split__pane--history'>
                    {list(historyView ? historyView.statusIds : ImmutableList(), {
                      key: 'history',
                      readingSurface: true,
                      view: historyView,
                      badgesFor: this.badgesForHistory,
                      hasMore: !!(historyView && historyView.hasMore),
                      isLoading: !!(historyView && (historyView.waiting || historyView.running)),
                      trackIntersection: true,
                      onLoadMore: this.handleLoadHistory,
                      prepend: this.renderNotices(historyView, 'history'),
                    })}
                  </div>
                </div>
              </React.Fragment>
            )}
          </Column>
        )}
      </TimelineSplitControllerCore>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class MixTimeline extends MixTimelinePage {}
