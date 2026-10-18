import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { createSelector } from 'reselect';
import { fetchStatus } from '../../actions/statuses';
import MissingIndicator from '../../components/missing_indicator';
import Column from '../ui/components/column';
import {
  hideStatus,
  revealStatus,
} from '../../actions/statuses';
import { makeGetStatus } from '../../selectors';
import ScrollContainer from 'mastodon/containers/scroll_container';
import ColumnBackButton from '../../components/column_back_button';
import ColumnHeader from '../../components/column_header';
import StatusContainer from '../../containers/status_container';
import { defineMessages, injectIntl } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { attachFullscreenListener, detachFullscreenListener, isFullscreen } from '../ui/util/fullscreen';
import Icon from 'mastodon/components/icon';
import DetailedHeaderContaier from '../status/containers/header_container';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  revealAll: { id: 'status.show_more_all', defaultMessage: 'Show more for all' },
  hideAll: { id: 'status.show_less_all', defaultMessage: 'Show less for all' },
  detailedStatus: { id: 'status.detailed_status', defaultMessage: 'Detailed conversation view' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();

  const getReferencesIds = createSelector([
    (_, { id }) => id,
    state => state.getIn(['contexts', 'references']),
  ], (statusId, contextReference) => {
    return ImmutableList(contextReference.get(statusId));
  });

  const mapStateToProps = (state, { columnId, params }) => {
    const uuid = columnId;
    const columns = state.getIn(['settings', 'columns']);
    const index = columns.findIndex(c => c.get('uuid') === uuid);
    const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'status_references', 'columnWidth']);
    const status         = getStatus(state, { id: params.statusId });
    const referencesIds  = status ? getReferencesIds(state, { id: status.get('id') }) : ImmutableList();

    return {
      status,
      referencesIds,
      columnWidth: columnWidth ?? defaultColumnWidth,
    };
  };

  return mapStateToProps;
};

export default @injectIntl
@connect(makeMapStateToProps)
class StatusReferences extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    status: ImmutablePropTypes.map,
    referencesIds: ImmutablePropTypes.list,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  state = {
    fullscreen: false,
  };

  componentWillMount () {
    this.props.dispatch(fetchStatus(this.props.params.statusId));
  }

  componentDidMount () {
    attachFullscreenListener(this.onFullScreenChange);
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.params.statusId !== this.props.params.statusId && nextProps.params.statusId) {
      this._scrolledIntoView = false;
      this.props.dispatch(fetchStatus(nextProps.params.statusId));
    }
  }

  handleToggleAll = () => {
    const { status, referencesIds } = this.props;
    const statusIds = [status.get('id')].concat(referencesIds.toJS());

    if (status.get('hidden')) {
      this.props.dispatch(revealStatus(statusIds));
    } else {
      this.props.dispatch(hideStatus(statusIds));
    }
  }

  handleMoveUp = id => {
    const { referencesIds } = this.props;

    const index = referencesIds.indexOf(id);
    if (index > 0) {
      this._selectChild(index - 1, true);
    }
  }

  handleMoveDown = id => {
    const { referencesIds } = this.props;

    const index = referencesIds.indexOf(id);
    if (index !== -1 && index + 1 < referencesIds.size) {
      this._selectChild(index + 1, false);
    }
  }

  _selectChild (index, align_top) {
    const container = this.node;
    const element = container.querySelectorAll('.focusable')[index];

    if (element) {
      if (align_top && container.scrollTop > element.offsetTop) {
        element.scrollIntoView(true);
      } else if (!align_top && container.scrollTop + container.clientHeight < element.offsetTop + element.offsetHeight) {
        element.scrollIntoView(false);
      }
      element.focus();
    }
  }

  renderChildren (list) {
    return list.map(id => (
      <StatusContainer
        key={id}
        id={id}
        onMoveUp={this.handleMoveUp}
        onMoveDown={this.handleMoveDown}
        contextType='thread'
        contextHostId={this.props.columnId ? `references:${this.props.columnId}:${this.props.params.statusId}` : `references:route:${this.props.params.statusId}`}
      />
    ));
  }

  setRef = c => {
    this.node = c;
  }

  componentWillUnmount () {
    detachFullscreenListener(this.onFullScreenChange);
  }

  onFullScreenChange = () => {
    this.setState({ fullscreen: isFullscreen() });
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['status_references', 'columnWidth'], value));
    }
  }

  render () {
    const { status, referencesIds, intl, multiColumn, columnWidth } = this.props;
    const { fullscreen } = this.state;

    if (status === null) {
      return (
        <Column>
          <ColumnBackButton multiColumn={multiColumn} />
          <MissingIndicator />
        </Column>
      );
    }

    let references;
    if (referencesIds && referencesIds.size > 0) {
      references = <div>{this.renderChildren(referencesIds)}</div>;
    }

    return (
      <Column bindToDocument={!multiColumn} label={intl.formatMessage(messages.detailedStatus)} columnWidth={columnWidth}>
        <ColumnHeader
          showBackButton
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
          extraButton={(
            <button className='column-header__button' title={intl.formatMessage(status.get('hidden') ? messages.revealAll : messages.hideAll)} aria-label={intl.formatMessage(status.get('hidden') ? messages.revealAll : messages.hideAll)} onClick={this.handleToggleAll} aria-pressed={status.get('hidden') ? 'false' : 'true'}><Icon id={status.get('hidden') ? 'eye-slash' : 'eye'} /></button>
          )}
        />

        <DetailedHeaderContaier statusId={status.get('id')} />

        <ScrollContainer scrollKey='reference'>
          <div className={classNames('scrollable', { fullscreen })} ref={this.setRef}>
            {references}
          </div>
        </ScrollContainer>
      </Column>
    );
  }

}
