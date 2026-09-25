import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage, injectIntl } from 'react-intl';
import { fromJS, List as ImmutableList } from 'immutable';
import DropdownMenu from 'mastodon/components/dropdown_menu';
import Icon from 'mastodon/components/icon';
import Avatar from 'mastodon/components/avatar';
import RelativeTimestamp from 'mastodon/components/relative_timestamp';

class PublicStatusHistory extends React.PureComponent {

  static propTypes = {
    statusId: PropTypes.string.isRequired,
    editedAt: PropTypes.string,
    historyUrl: PropTypes.string.isRequired,
    language: PropTypes.string,
    onOpenRevision: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  state = {
    openDropdownId: null,
    openedViaKeyboard: false,
    loading: false,
    items: ImmutableList(),
    loaded: false,
  };

  handleOpen = (id, _onItemClick, keyboard) => {
    this.setState({ openDropdownId: id, openedViaKeyboard: keyboard });

    if (!this.state.loaded && !this.state.loading) {
      this.loadHistory();
    }
  }

  handleClose = (id) => {
    if (this.state.openDropdownId === id) {
      this.setState({ openDropdownId: null, openedViaKeyboard: false });
    }
  }

  handleItemClick = (_item, index) => {
    const revision = this.state.items.get(index);

    if (revision && this.props.onOpenRevision) {
      this.props.onOpenRevision(revision, this.props.language);
    }
  }

  loadHistory () {
    this.setState({ loading: true });

    fetch(this.props.historyUrl, {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    }).then(response => {
      if (!response.ok) {
        throw new Error(response.status);
      }

      return response.json();
    }).then(data => {
      const revisions = Array.isArray(data) ? data : [];
      const items = revisions.map((item, index) => ({
        ...item,
        original: index === 0,
      })).reverse();

      this.setState({ items: fromJS(items), loading: false, loaded: true });
    }).catch(() => {
      this.setState({ loading: false });
    });
  }

  renderHeader = items => {
    const count = items ? items.size || items.length || 0 : 0;

    if (count === 0) {
      return <FormattedMessage id='status.history.empty' defaultMessage='No edit history' />;
    }

    return (
      <FormattedMessage id='status.edited_x_times' defaultMessage='Edited {count, plural, one {# time} other {# times}}' values={{ count: Math.max(count - 1, 0) }} />
    );
  }

  renderAccount = account => {
    if (!account || !account.get) {
      return '';
    }

    return (
      <span className='inline-account'>
        <Avatar size={13} account={account} /> <strong>{account.get('username')}</strong>
      </span>
    );
  }

  renderItem = (item, index, { onClick, onKeyPress }) => {
    const formattedDate = <RelativeTimestamp timestamp={item.get('created_at')} short={false} />;
    const formattedName = this.renderAccount(item.get('account'));
    const label = item.get('original') ? (
      <FormattedMessage id='status.history.created' defaultMessage='{name} created {date}' values={{ name: formattedName, date: formattedDate }} />
    ) : (
      <FormattedMessage id='status.history.edited' defaultMessage='{name} edited {date}' values={{ name: formattedName, date: formattedDate }} />
    );

    return (
      <li className='dropdown-menu__item edited-timestamp__history__item' key={`${item.get('created_at')}-${index}`}>
        <button type='button' data-index={index} onClick={onClick} onKeyPress={onKeyPress}>{label}</button>
      </li>
    );
  }

  render () {
    const { editedAt, intl, statusId } = this.props;

    if (!editedAt || !statusId) {
      return null;
    }

    return (
      <span className='edited-timestamp'>
        <DropdownMenu
          statusId={statusId}
          items={this.state.items.toArray()}
          loading={this.state.loading}
          scrollable
          renderItem={this.renderItem}
          renderHeader={this.renderHeader}
          onItemClick={this.handleItemClick}
          onOpen={this.handleOpen}
          onClose={this.handleClose}
          openDropdownId={this.state.openDropdownId}
          openedViaKeyboard={this.state.openedViaKeyboard}
        >
          <button type='button' className='dropdown-menu__text-button'>
            <FormattedMessage id='status.edited' defaultMessage='Edited {date}' values={{ date: intl.formatDate(editedAt, { hour12: false, month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }) }} /> <Icon id='caret-down' />
          </button>
        </DropdownMenu>
      </span>
    );
  }

}

export default injectIntl(PublicStatusHistory);
