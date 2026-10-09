import React from 'react';
import { connect } from 'react-redux';
import { Link } from 'react-router-dom';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { addColumn, changeColumnParams, moveColumn, removeColumn } from '../../actions/columns';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { isMixEnabled } from 'mastodon/mix/availability';
import { plainMix } from 'mastodon/mix/definition';
import messages from './messages';
import SourceList from './components/source_list';

const findMix = (state, id) => {
  if (!id) {
    return null;
  }

  return state.getIn(['settings', 'mixes'], ImmutableList()).find(item => item && item.get('id') === String(id)) || null;
};

const mapStateToProps = (state, { columnId, params }) => {
  const mixId = params && params.id ? String(params.id) : null;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns && columnId ? columns.findIndex(column => column.get('uuid') === columnId) : -1;
  const columnWidth = index >= 0 ? columns.get(index).getIn(['params', 'columnWidth']) : null;

  return {
    mixId,
    mix: findMix(state, mixId),
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
    enabled: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
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
    const { intl, columnId, mixId, mix, enabled, multiColumn, columnWidth } = this.props;
    const mode = mixTimelineMode({ enabled, mix });
    const plain = mode === 'ready' ? plainMix(mix) : null;
    const title = plain ? plain.title : intl.formatMessage(messages.heading);

    let body;

    if (mode === 'unavailable') {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.unavailable)}</p>;
    } else if (mode === 'deleted') {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.deleted)}</p>;
    } else {
      body = (
        <div className='scrollable mix-editor'>
          <p>{intl.formatMessage(messages.notMerged)}</p>
          <p>{intl.formatMessage(messages.notShared)}</p>
          <SourceList sources={plain.sources} intl={intl} />
          <Link className='button button-secondary' to={`/mixes/${mixId}/edit`}>{intl.formatMessage(messages.edit)}</Link>
        </div>
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
