import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import Overlay from 'react-overlays/Overlay';
import { DropdownMenu } from 'mastodon/components/dropdown_menu';
import { createFavouriteTag } from 'mastodon/actions/favourite_tags';
import { me } from 'mastodon/initial_state';
import { copyText } from 'mastodon/utils/clipboard';
import { collectStatusHashtags } from 'mastodon/utils/status_hashtags';

const messages = defineMessages({
  browse: { id: 'hashtag.browse', defaultMessage: 'View posts with #{hashtag}' },
  browseAccount: { id: 'hashtag.browse_from_account', defaultMessage: 'View {name}\'s posts with #{hashtag}' },
  favourite: { id: 'hashtag.favourite_add', defaultMessage: 'Add to favorites' },
  copy: { id: 'hashtag.copy', defaultMessage: 'Copy hashtag' },
  copyAll: { id: 'hashtag.copy_all', defaultMessage: 'Copy hashtags' },
  mute: { id: 'hashtag.mute', defaultMessage: 'Mute #{hashtag}' },
});

const popperConfig = {
  strategy: 'fixed',
};

class HashtagMenuController extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    intl: PropTypes.object.isRequired,
    accounts: ImmutablePropTypes.map,
    statuses: ImmutablePropTypes.map,
    signedIn: PropTypes.bool,
    onAddFavourite: PropTypes.func.isRequired,
  };

  state = {
    element: null,
    hashtag: '',
    accountId: '',
    statusId: '',
    accountName: '',
  };

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, true);
  }

  componentWillUnmount () {
    document.removeEventListener('click', this.handleDocumentClick, true);
  }

  isSignedIn () {
    if (typeof this.props.signedIn === 'boolean') {
      return this.props.signedIn;
    }

    return !!me;
  }

  handleClose = () => {
    this.setState({
      element: null,
      hashtag: '',
      accountId: '',
      statusId: '',
      accountName: '',
    });
  }

  findTarget = () => {
    return this.state.element;
  }

  handleDocumentClick = event => {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
      return;
    }

    const origin = event.target && event.target.nodeType === Node.ELEMENT_NODE
      ? event.target
      : event.target && event.target.parentElement;
    const link = origin && origin.closest && origin.closest('a[data-menu-hashtag]');

    if (!link) {
      return;
    }

    const hashtag = link.getAttribute('data-menu-hashtag') || '';

    if (!hashtag) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    if (this.state.element === link) {
      this.handleClose();
      return;
    }

    this.setState({
      element: link,
      hashtag,
      accountId: link.getAttribute('data-account-id') || '',
      statusId: link.getAttribute('data-status-id') || '',
      accountName: link.getAttribute('data-account-name') || '',
    });
  }

  accountLabel () {
    const account = this.props.accounts && this.props.accounts.get(this.state.accountId);
    const storedName = account && (account.get('display_name') || account.get('username') || account.get('acct'));

    return storedName || this.state.accountName || '';
  }

  copyHashtag = () => {
    copyText(`#${this.state.hashtag.replace(/^[#＃]/, '')}`);
  }

  copyAllHashtags = () => {
    const status = this.props.statuses && this.props.statuses.get(this.state.statusId);
    const html = status && status.get('contentHtml');
    const labels = collectStatusHashtags(html || '').map(hashtag => hashtag.text);

    copyText(labels.join(' '));
  }

  openFilters = () => {
    const opened = window.open('/filters', '_blank', 'noopener,noreferrer');

    if (opened) {
      opened.opener = null;
    }
  }

  menuItems () {
    const { intl } = this.props;
    const hashtag = this.state.hashtag;
    const tagPath = `/timelines/tag/${encodeURIComponent(hashtag)}`;
    const accountPath = `/accounts/${this.state.accountId}/posts/${encodeURIComponent(hashtag)}`;
    const items = [
      {
        text: intl.formatMessage(messages.browse, { hashtag }),
        href: tagPath,
        to: tagPath,
      },
      {
        text: intl.formatMessage(messages.browseAccount, { hashtag, name: this.accountLabel() }),
        href: accountPath,
        to: accountPath,
      },
      null,
    ];

    if (this.isSignedIn()) {
      items.push({
        text: intl.formatMessage(messages.favourite),
        action: () => this.props.onAddFavourite(hashtag),
      });
    }

    items.push(
      {
        text: intl.formatMessage(messages.copy),
        action: this.copyHashtag,
      },
      {
        text: intl.formatMessage(messages.copyAll),
        action: this.copyAllHashtags,
      },
    );

    if (this.isSignedIn()) {
      items.push(null, {
        text: intl.formatMessage(messages.mute, { hashtag }),
        href: '/filters',
        target: '_blank',
        dangerous: true,
        action: this.openFilters,
      });
    }

    return items;
  }

  handleItemClick = event => {
    if (event.button !== 0 || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
      return;
    }

    const index = Number(event.currentTarget.getAttribute('data-index'));
    const item = this.menuItems()[index];

    event.preventDefault();
    event.stopPropagation();
    this.handleClose();

    if (!item) {
      return;
    }

    if (typeof item.action === 'function') {
      item.action(event);
      return;
    }

    if (item.to && this.context.router) {
      this.context.router.history.push(item.to);
    }
  }

  render () {
    if (!this.state.element) {
      return null;
    }

    return (
      <Overlay show offset={[5, 5]} placement='bottom' flip target={this.findTarget} popperConfig={popperConfig}>
        {({ props, arrowProps, placement }) => (
          <div {...props}>
            <div className={`dropdown-animation dropdown-menu ${placement}`}>
              <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
              <DropdownMenu
                items={this.menuItems()}
                onClose={this.handleClose}
                onItemClick={this.handleItemClick}
              />
            </div>
          </div>
        )}
      </Overlay>
    );
  }

}

const mapStateToProps = state => ({
  accounts: state.get('accounts'),
  statuses: state.get('statuses'),
});

const mapDispatchToProps = dispatch => ({
  onAddFavourite(name) {
    dispatch(createFavouriteTag(name));
  },
});

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(HashtagMenuController));
