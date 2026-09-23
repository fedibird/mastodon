import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage, injectIntl } from 'react-intl';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { openModal } from '../../actions/modal';
import { fetchHistory } from '../../actions/history';
import { openDropdownMenu, closeDropdownMenu } from '../../actions/dropdown_menu';
import DropdownMenu from '../dropdown_menu';
import Icon from '../icon';
import RelativeTimestamp from '../relative_timestamp';

const mapStateToProps = (state, { statusId }) => ({
  openDropdownId: state.getIn(['dropdown_menu', 'openId']),
  openedViaKeyboard: state.getIn(['dropdown_menu', 'keyboard']),
  items: state.getIn(['history', statusId, 'items'], ImmutableList()),
  loading: state.getIn(['history', statusId, 'loading'], false),
});

const mapDispatchToProps = (dispatch, { statusId }) => ({
  onOpen(id, onItemClick, keyboard) {
    dispatch(fetchHistory(statusId));
    dispatch(openDropdownMenu(id, keyboard));
  },

  onClose(id) {
    dispatch(closeDropdownMenu(id));
  },

  onItemClick(index) {
    dispatch(openModal('COMPARE_HISTORY', { index, statusId }));
  },
});

class EditedTimestamp extends React.PureComponent {

  static propTypes = {
    statusId: PropTypes.string,
    timestamp: PropTypes.string,
    intl: PropTypes.object.isRequired,
    items: ImmutablePropTypes.list,
    loading: PropTypes.bool,
    onOpen: PropTypes.func.isRequired,
    onClose: PropTypes.func.isRequired,
    onItemClick: PropTypes.func.isRequired,
    openDropdownId: PropTypes.string,
    openedViaKeyboard: PropTypes.bool,
  };

  handleItemClick = (_item, index) => {
    this.props.onItemClick(index);
  };

  renderHeader = items => {
    const count = items ? items.size || items.length || 0 : 0;

    if (count === 0) {
      return <FormattedMessage id='status.history.empty' defaultMessage='No edit history' />;
    }

    return (
      <FormattedMessage id='status.edited_x_times' defaultMessage='Edited {count, plural, one {# time} other {# times}}' values={{ count: Math.max(count - 1, 0) }} />
    );
  };

  renderItem = (item, index, { onClick, onKeyPress }) => {
    const formattedDate = <RelativeTimestamp timestamp={item.get('created_at')} short={false} />;
    const label = item.get('original') ? (
      <FormattedMessage id='status.history.created' defaultMessage='{name} created {date}' values={{ name: '', date: formattedDate }} />
    ) : (
      <FormattedMessage id='status.history.edited' defaultMessage='{name} edited {date}' values={{ name: '', date: formattedDate }} />
    );

    return (
      <li className='dropdown-menu__item edited-timestamp__history__item' key={`${item.get('created_at')}-${index}`}>
        <button type='button' data-index={index} onClick={onClick} onKeyPress={onKeyPress}>{label}</button>
      </li>
    );
  };

  render () {
    const { timestamp, intl, statusId, items } = this.props;

    if (!timestamp || !statusId) {
      return null;
    }

    return (
      <span className='edited-timestamp'>
        {' · '}
        <DropdownMenu
          statusId={statusId}
          items={(items || ImmutableList()).toArray()}
          loading={this.props.loading}
          scrollable
          renderItem={this.renderItem}
          renderHeader={this.renderHeader}
          onItemClick={this.handleItemClick}
          onOpen={this.props.onOpen}
          onClose={this.props.onClose}
          openDropdownId={this.props.openDropdownId}
          openedViaKeyboard={this.props.openedViaKeyboard}
        >
          <button type='button' className='dropdown-menu__text-button'>
            <FormattedMessage id='status.edited' defaultMessage='Edited {date}' values={{ date: intl.formatDate(timestamp, { hour12: false, month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }) }} /> <Icon id='caret-down' />
          </button>
        </DropdownMenu>
      </span>
    );
  }

}

export default connect(mapStateToProps, mapDispatchToProps)(injectIntl(EditedTimestamp));
