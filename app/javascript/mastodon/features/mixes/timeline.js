import React from 'react';
import { connect } from 'react-redux';
import { Link } from 'react-router-dom';
import PropTypes from 'prop-types';
import { FormattedMessage, injectIntl } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import ImmutablePropTypes from 'react-immutable-proptypes';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import StatusList from '../../components/status_list';
import { addColumn, changeColumnParams, moveColumn, removeColumn } from '../../actions/columns';
import { closeMixTimeline, loadMixTimeline, mixColumnKey, retryMixSource } from '../../actions/mix_timelines';
import { closeMixStream, openMixStream, pinMixStream, revealMixStream } from '../../actions/mix_streaming';
import { defaultColumnWidth, me } from 'mastodon/initial_state';
import { isMixEnabled } from 'mastodon/mix/availability';
import { plainMix } from 'mastodon/mix/definition';
import { sourceKey } from 'mastodon/mix/source';
import { mixTimelineView } from 'mastodon/mix/view';
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
    view: mixTimelineView(timeline, state.get('statuses'), state.get('filters'), me),
    enabled: isMixEnabled(),
    columnWidth: columnWidth || defaultColumnWidth,
  };
};

export const mixTimelineMode = ({ enabled, mix }) => {
  if (!enabled) {
    return 'unavailable';
  }

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
    view: PropTypes.shape({
      statusIds: ImmutablePropTypes.list,
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
    }),
    enabled: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  componentDidMount () {
    this.loadTimeline();
  }

  componentDidUpdate (prevProps) {
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

  handleScrollToTop = () => {
    this.props.dispatch(pinMixStream(this.props.columnKey, true));
  };

  handleScroll = () => {
    this.props.dispatch(pinMixStream(this.props.columnKey, false));
  };

  handleReveal = () => {
    this.props.dispatch(revealMixStream(this.props.columnKey));
  };

  contextTypeForId = (id) => {
    const contexts = this.props.view && this.props.view.contextById;

    return contexts ? contexts[id] : null;
  };

  warningTitlesForId = (id) => {
    const warnings = this.props.view && this.props.view.warningsById;

    return warnings && warnings[id] ? warnings[id] : [];
  };

  handleRetry = (event) => {
    const sourceKey = event.currentTarget.getAttribute('data-source-key');

    if (sourceKey) {
      this.props.dispatch(retryMixSource(this.props.columnKey, this.props.mix, sourceKey));
    }
  };

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

  handleHeaderClick = () => {
    if (this.column) {
      this.column.scrollTop();
    }
  };

  setRef = (c) => {
    this.column = c;
  };

  render () {
    const { intl, columnId, mixId, mix, enabled, multiColumn, columnWidth, view } = this.props;
    const mode = mixTimelineMode({ enabled, mix });
    const plain = mode === 'ready' ? plainMix(mix) : null;
    const title = plain ? plain.title : intl.formatMessage(messages.heading);
    const statusIds = view && view.statusIds ? view.statusIds : ImmutableList();
    const notices = [];

    if (view && view.suspended && view.suspended.length) {
      view.suspended.forEach(item => {
        notices.push({
          key: item.key,
          text: intl.formatMessage(messages.incomplete, { name: item.label || item.key }),
          retry: true,
        });
      });
    } else if (view && !view.orderGuaranteed && !view.waiting && view.errors.length) {
      notices.push({ key: 'order', text: intl.formatMessage(messages.orderPartial) });
    }

    if (view && view.pendingCount) {
      notices.push({
        key: 'pending',
        text: intl.formatMessage(messages.pendingPosts, { count: view.pendingCount }),
        reveal: true,
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

    if (view) {
      view.errors.forEach(item => {
        const name = item.label || item.key;
        let message = messages.sourceUnavailable;

        if (item.error === 'forbidden') {
          message = messages.sourceForbidden;
        } else if (item.error === 'not_found') {
          message = messages.sourceMissing;
        }

        const rateLimited = item.error === 'rate_limit' && item.retryAt && item.retryAt > Date.now();

        notices.push({
          key: item.key,
          text: intl.formatMessage(message, { name }),
          retry: item.error === 'server' || (item.error === 'rate_limit' && !rateLimited),
        });
      });
    }

    const noticeNodes = notices.map(notice => (
      <p key={notice.key || notice.text} className='mix-editor__notice'>
        {notice.reveal ? null : (notice.text || notice)}
        {notice.retry && (
          <button type='button' className='button button-secondary' data-source-key={notice.key} onClick={this.handleRetry}>
            {intl.formatMessage(messages.retrySource, { name: notice.key })}
          </button>
        )}
        {notice.reveal && (
          <button type='button' className='button button-secondary' onClick={this.handleReveal}>
            {notice.text}
          </button>
        )}
      </p>
    ));

    let body;

    if (mode === 'unavailable') {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.unavailable)}</p>;
    } else if (mode === 'deleted') {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.deleted)}</p>;
    } else {
      body = (
        <StatusList
          statusIds={statusIds}
          scrollKey={`mix-${this.props.columnKey}`}
          hasMore={!!(view && view.hasMore)}
          isLoading={!!(view && (view.waiting || view.running))}
          onLoadMore={this.handleLoadMore}
          onScrollToTop={this.handleScrollToTop}
          onScroll={this.handleScroll}
          contextTypeForId={this.contextTypeForId}
          warningTitlesForId={this.warningTitlesForId}
          emptyMessage={<FormattedMessage id='mixes.empty_timeline' defaultMessage='No posts in this mix yet.' />}
          prepend={(
            <div className='mix-editor'>
              <p>{intl.formatMessage(messages.notShared)}</p>
              {noticeNodes}
              <Link className='button button-secondary' to={`/mixes/${mixId}/edit`}>{intl.formatMessage(messages.edit)}</Link>
            </div>
          )}
        />
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={title} columnWidth={columnWidth}>
        <ColumnHeader
          icon='random'
          title={title}
          onPin={mode === 'ready' ? this.handlePin : undefined}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          onWidthChange={this.handleWidthChange}
          pinned={!!columnId}
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          showBackButton
        />
        {body}
      </Column>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class MixTimeline extends MixTimelinePage {}
