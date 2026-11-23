import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import Overlay from 'react-overlays/Overlay';
import { DropdownMenu } from 'mastodon/components/dropdown_menu';
import { createFavouriteTag } from 'mastodon/actions/favourite_tags';
import { openModal } from 'mastodon/actions/modal';
import { me } from 'mastodon/initial_state';
import { copyText } from 'mastodon/utils/clipboard';
import { accountUrlForHashtag } from 'mastodon/utils/account_tag_url';
import { collectCopyHashtags } from 'mastodon/utils/status_hashtags';
import { hashtagMenuBoundImages, hashtagMenuStoredIdentity, projectHashtagLabel, registerHashtagMenuBinding, registerHashtagMenuConcealer, replaceHashtagSlot } from 'mastodon/features/emoji/hashtag_menu_names';
import { recordEmojiMuteText } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { rememberEmojiMuteHashtagSlot } from 'mastodon/features/emoji/emoji_mute_sources';
import { emojiMuteTextIndexFromState, SUPPRESS_UNVERIFIED_INDEX, suppressUnicodeEmoji, UNVERIFIED_EMOJI_PLACEHOLDER } from 'mastodon/features/emoji/emoji_mute_text';

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
    onMuteHashtag: PropTypes.func.isRequired,
    emojiMuteTextIndex: PropTypes.object,
  };

  state = {
    element: null,
    hashtag: '',
    imageRanges: [],
    hashtagImages: [],
    hashtagUrl: '',
    accountId: '',
    statusId: '',
    accountName: '',
  };

  componentDidMount () {
    document.addEventListener('click', this.handleDocumentClick, true);
    this.unregisterMenuConcealer = registerHashtagMenuConcealer(this.concealForSuppress);
    this.unregisterMenuBinding = registerHashtagMenuBinding(this.syncBinding);
  }

  componentWillUnmount () {
    document.removeEventListener('click', this.handleDocumentClick, true);

    if (this.unregisterMenuConcealer) {
      this.unregisterMenuConcealer();
    }

    if (this.unregisterMenuBinding) {
      this.unregisterMenuBinding();
    }
  }

  actionRanges () {
    const link = this.state.element;

    if (link && link.isConnected) {
      const identity = hashtagMenuStoredIdentity(link);

      if (identity && identity.name === this.state.hashtag) {
        return identity.imageRanges || [];
      }
    }

    return this.state.imageRanges || [];
  }

  syncBinding = link => {
    if (!link || this.state.element !== link) {
      return;
    }

    if (!link.isConnected) {
      this.handleClose();
      return;
    }

    const identity = hashtagMenuStoredIdentity(link);

    if (!identity.name || identity.name !== this.state.hashtag) {
      this.handleClose();
      return;
    }

    const next = this.actionRanges();
    const prev = this.state.imageRanges || [];
    const same = next.length === prev.length && next.every((range, index) => range[0] === prev[index][0] && range[1] === prev[index][1]);
    const nextImages = this.actionImages();
    const prevImages = this.state.hashtagImages || [];
    const sameImages = nextImages.length === prevImages.length && nextImages.every((image, index) => {
      const previous = prevImages[index] || {};

      return image.start === previous.start
        && image.end === previous.end
        && (image.id || '') === (previous.id || '')
        && (image.shortcode || '') === (previous.shortcode || '')
        && (image.domain || '') === (previous.domain || '');
    });

    if (!same || !sameImages) {
      this.setState({ imageRanges: next, hashtagImages: nextImages });
    }
  }

  setMenuNode = node => {
    this.menuNode = node;
  }

  // Only the menu this controller opened. Post and profile menus use the
  // same dropdown class and can still be in the document.
  concealForSuppress = sink => {
    const menu = this.menuNode;

    if (!menu || !menu.isConnected || !this.state.element || !this.state.hashtag) {
      return;
    }

    const ranges = this.actionRanges();
    const images = this.actionImages();
    const raw = this.state.hashtag;
    const rendered = projectHashtagLabel(raw, ranges, this.props.emojiMuteTextIndex, images);
    const shown = projectHashtagLabel(raw, ranges, SUPPRESS_UNVERIFIED_INDEX, images);
    const label = shown !== '' ? shown : UNVERIFIED_EMOJI_PLACEHOLDER;
    const forms = [rendered, raw, suppressUnicodeEmoji(rendered), suppressUnicodeEmoji(raw)].filter((value, index, list) => value && list.indexOf(value) === index);

    const owner = menu.ownerDocument || document;
    const walker = owner.createTreeWalker(menu, NodeFilter.SHOW_TEXT, null);
    let node = walker.nextNode();

    while (node) {
      const value = node.nodeValue || '';
      let next = value;
      let logical = value;

      forms.forEach(form => {
        next = replaceHashtagSlot(next, form, label);
        logical = replaceHashtagSlot(logical, form, raw);
      });

      if (next !== value) {
        const noted = sink && sink.find(record => record.kind === 'text' && record.node === node);

        rememberEmojiMuteHashtagSlot(node, { text: logical, name: raw, ranges, images });

        if (noted) {
          noted.value = logical;
        } else {
          recordEmojiMuteText(sink, node);
        }

        node.nodeValue = next;
      }

      node = walker.nextNode();
    }
  }

  actionImages () {
    const link = this.state.element;

    if (link && link.isConnected) {
      const identity = hashtagMenuStoredIdentity(link);

      const bound = hashtagMenuBoundImages(link);

      if (bound && identity.name === this.state.hashtag) {
        return bound;
      }
    }

    return this.state.hashtagImages || [];
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
      imageRanges: [],
      hashtagImages: [],
      hashtagUrl: '',
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

    const identity = hashtagMenuStoredIdentity(link);
    const hashtag = identity.name;

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
      imageRanges: identity.imageRanges,
      hashtagImages: identity.images || [],
      hashtagUrl: link.href || '',
      accountId: link.getAttribute('data-account-id') || '',
      statusId: link.getAttribute('data-status-id') || '',
      accountName: link.getAttribute('data-account-name') || '',
    });
  }

  accountLabel () {
    const account = this.props.accounts && this.props.accounts.get(this.state.accountId);
    const storedName = account && (account.get('username') || account.get('acct'));

    return storedName || this.state.accountName || '';
  }

  copyHashtag = () => {
    copyText(`#${this.state.hashtag.replace(/^[#＃]/, '')}`);
  }

  copyAllHashtags = () => {
    const status = this.props.statuses && this.props.statuses.get(this.state.statusId);
    const html = status && status.get('contentHtml');
    const labels = collectCopyHashtags(html || '', status && status.get('tags')).map(hashtag => hashtag.text);

    copyText(labels.join(' '));
  }

  accountAcct () {
    const account = this.props.accounts && this.props.accounts.get(this.state.accountId);

    return account && account.get('acct') ? String(account.get('acct')) : '';
  }

  // Only an account that is known to be local is treated as local. Anything else
  // (remote, or not in the store yet) never gets a guessed public URL.
  isLocalAccount () {
    const acct = this.accountAcct();

    return acct !== '' && !acct.includes('@');
  }

  // href is used only by direct navigation (new tab, copied link), so it points to
  // the original public page: Fedibird's signed-out pages for local posts, and the
  // remote server's own tag link for remote posts. Out-of-band badges carry a
  // Fedibird URL even for remote posts (TagSerializer#url), which is not the original,
  // so a same-origin link of a remote post is treated as unknown (null, no href).
  tagHref () {
    const { hashtag, hashtagUrl } = this.state;

    if (this.isLocalAccount()) {
      return `${window.location.origin}/tags/${encodeURIComponent(hashtag)}`;
    }

    try {
      const url = new URL(hashtagUrl);

      if ((url.protocol === 'https:' || url.protocol === 'http:') && url.origin !== window.location.origin) {
        return url.href;
      }
    } catch (e) {
      // not a usable URL
    }

    return null;
  }

  // href is the public URL from tags[].account_url when this label matches one tag.
  // Local HTML-only tags keep the signed-out page. Remote misses stay without href.
  // The in-app `to` path is chosen separately and does not use this URL.
  accountTagHref () {
    const fromStatus = this.accountUrlFromStatus();

    if (fromStatus) {
      return fromStatus;
    }

    if (this.isLocalAccount()) {
      return `${window.location.origin}/@${encodeURIComponent(this.accountAcct())}/tagged/${encodeURIComponent(this.state.hashtag)}`;
    }

    return null;
  }

  accountUrlFromStatus () {
    const status = this.props.statuses && this.props.statuses.get(this.state.statusId);

    if (!status) {
      return null;
    }

    try {
      return accountUrlForHashtag(status.get('tags'), this.state.hashtag);
    } catch (e) {
      return null;
    }
  }

  visibleHashtag () {
    const shown = projectHashtagLabel(this.state.hashtag, this.actionRanges(), this.props.emojiMuteTextIndex, this.actionImages());

    // An empty replacement is a real projection. The action value stays original.
    return shown !== '' ? shown : UNVERIFIED_EMOJI_PLACEHOLDER;
  }

  menuItems () {
    const { intl } = this.props;
    const hashtag = this.state.hashtag;
    const label = this.visibleHashtag();
    const tagPath = `/timelines/tag/${encodeURIComponent(hashtag)}`;
    const accountPath = `/accounts/${this.state.accountId}/posts/${encodeURIComponent(hashtag)}`;
    const items = [
      {
        text: intl.formatMessage(messages.browse, { hashtag: label }),
        href: this.tagHref(),
        to: tagPath,
      },
      {
        text: intl.formatMessage(messages.browseAccount, { hashtag: label, name: this.accountLabel() }),
        href: this.accountTagHref(),
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
        text: intl.formatMessage(messages.mute, { hashtag: label }),
        href: null,
        target: null,
        action: () => this.props.onMuteHashtag(hashtag, this.actionRanges(), this.actionImages()),
        dangerous: true,
      });
    }

    return items;
  }

  handleItemClick = event => {
    if (event.type === 'click' && event.button !== 0) {
      return;
    }

    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
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
            <div className={`dropdown-animation dropdown-menu ${placement}`} ref={this.setMenuNode}>
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
  emojiMuteTextIndex: emojiMuteTextIndexFromState(state),
});

const mapDispatchToProps = dispatch => ({
  onAddFavourite(name) {
    dispatch(createFavouriteTag(name));
  },

  onMuteHashtag(hashtag, imageRanges, hashtagImages) {
    dispatch(openModal('HASHTAG_MUTE', { hashtag, imageRanges: imageRanges || [], hashtagImages: hashtagImages || [] }));
  },
});

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(HashtagMenuController));
