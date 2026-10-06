import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from '../../components/column';
import ColumnBackButton from '../../components/column_back_button';
import ColumnHeader from '../../components/column_header';
import { addColumn, removeColumn, moveColumn } from '../../actions/columns';
import { FormattedMessage, defineMessages, injectIntl } from 'react-intl';
import { connectListStream } from '../../actions/streaming';
import { expandListTimeline } from '../../actions/timelines';
import { fetchList, deleteList, updateList } from '../../actions/lists';
import { openModal } from '../../actions/modal';
import MissingIndicator from '../../components/missing_indicator';
import LoadingIndicator from '../../components/loading_indicator';
import Icon from 'mastodon/components/icon';
import RadioButton from 'mastodon/components/radio_button';
import { defaultColumnWidth, new_features_policy } from 'mastodon/initial_state';
import PortableComposer from '../compose/portable_composer';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  deleteMessage: { id: 'confirmations.delete_list.message', defaultMessage: 'Are you sure you want to permanently delete this list?' },
  deleteConfirm: { id: 'confirmations.delete_list.confirm', defaultMessage: 'Delete' },
  followed:   { id: 'lists.replies_policy.followed', defaultMessage: 'Any followed user' },
  none:    { id: 'lists.replies_policy.none', defaultMessage: 'No one' },
  list:  { id: 'lists.replies_policy.list', defaultMessage: 'Members of the list' },
});

const mapStateToProps = (state, { columnId, params }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns.findIndex(c => c.get('uuid') === uuid);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'list', 'columnWidth']);

  return {
    list: state.getIn(['lists', params.id]),
    hasUnread: state.getIn(['timelines', `list:${params.id}`, 'unread']) > 0,
    columnWidth: columnWidth ?? defaultColumnWidth,
  };
};

export default @connect(mapStateToProps)
@injectIntl
class ListTimeline extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    columnId: PropTypes.string,
    hasUnread: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    list: PropTypes.oneOfType([ImmutablePropTypes.map, PropTypes.bool]),
    intl: PropTypes.object.isRequired,
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('LIST', { id: this.props.params.id }));
      this.context.router.history.push('/');
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
    const { dispatch } = this.props;
    const { id } = this.props.params;

    dispatch(fetchList(id));
    dispatch(expandListTimeline(id));

    this.disconnect = dispatch(connectListStream(id));
  }

  componentWillReceiveProps (nextProps) {
    const { dispatch } = this.props;
    const { id } = nextProps.params;

    if (id !== this.props.params.id) {
      if (this.disconnect) {
        this.disconnect();
        this.disconnect = null;
      }

      dispatch(fetchList(id));
      dispatch(expandListTimeline(id));

      this.disconnect = dispatch(connectListStream(id));
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
    const { id } = this.props.params;
    this.props.dispatch(expandListTimeline(id, { maxId }));
  }

  handleEditClick = () => {
    this.props.dispatch(openModal('LIST_EDITOR', { listId: this.props.params.id }));
  }

  handleDeleteClick = () => {
    const { dispatch, columnId, intl } = this.props;
    const { id } = this.props.params;

    dispatch(openModal('CONFIRM', {
      message: intl.formatMessage(messages.deleteMessage),
      confirm: intl.formatMessage(messages.deleteConfirm),
      onConfirm: () => {
        dispatch(deleteList(id));

        if (!!columnId) {
          dispatch(removeColumn(columnId));
        } else {
          this.context.router.history.push('/lists');
        }
      },
    }));
  }

  handleRepliesPolicyChange = ({ target }) => {
    const { dispatch } = this.props;
    const { id } = this.props.params;
    dispatch(updateList(id, undefined, false, target.value));
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['list', 'columnWidth'], value));
    }
  }

  render () {
    const { hasUnread, columnId, multiColumn, list, columnWidth, intl } = this.props;
    const { id } = this.props.params;
    const pinned = !!columnId;
    const title  = list ? list.get('title') : id;
    const replies_policy = list ? list.get('replies_policy') : undefined;
    const composerId = columnId ? `portable:list-column:${columnId}` : `portable:list-route:${id}`;
    const portableComposer = new_features_policy === 'tester' ? (
      <PortableComposer key={composerId} composerId={composerId} />
    ) : null;

    if (typeof list === 'undefined') {
      return (
        <Column>
          <div className='scrollable'>
            <LoadingIndicator />
          </div>
        </Column>
      );
    } else if (list === false) {
      return (
        <Column>
          <ColumnBackButton multiColumn={multiColumn} />
          <MissingIndicator />
        </Column>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={title} columnWidth={columnWidth}>
        <ColumnHeader
          icon='list-ul'
          active={hasUnread}
          title={title}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <div className='column-settings__row column-header__links'>
            <button className='text-btn column-header__setting-btn' tabIndex='0' onClick={this.handleEditClick}>
              <Icon id='pencil' /> <FormattedMessage id='lists.edit' defaultMessage='Edit list' />
            </button>

            <button className='text-btn column-header__setting-btn' tabIndex='0' onClick={this.handleDeleteClick}>
              <Icon id='trash' /> <FormattedMessage id='lists.delete' defaultMessage='Delete list' />
            </button>
          </div>

          { replies_policy !== undefined && (
            <div role='group' aria-labelledby={`list-${id}-replies-policy`}>
              <span id={`list-${id}-replies-policy`} className='column-settings__section'>
                <FormattedMessage id='lists.replies_policy.title' defaultMessage='Show replies to:' />
              </span>
              <div className='column-settings__row'>
                { ['none', 'list', 'followed'].map(policy => (
                  <RadioButton name='order' key={policy} value={policy} label={intl.formatMessage(messages[policy])} checked={replies_policy === policy} onChange={this.handleRepliesPolicyChange} />
                ))}
              </div>
            </div>
          )}
        </ColumnHeader>

        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`list_timeline-${columnId}`}
          timelineId={`list:${id}`}
          onLoadMore={this.handleLoadMore}
          emptyMessage={<FormattedMessage id='empty_column.list' defaultMessage='There is nothing in this list yet. When members of this list post new statuses, they will appear here.' />}
          bindToDocument={!multiColumn}
          prepend={portableComposer}
          alwaysPrepend={!!portableComposer}
        />
      </Column>
    );
  }

}
