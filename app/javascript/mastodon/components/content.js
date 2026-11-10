import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl, defineMessages } from 'react-intl';
import { autoPlayEmoji } from 'mastodon/initial_state';
import { customEmojiTarget, withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';
import { linkTargetEmojiRemains, replaceEmojiInDisplayHtml, retainMutedEmojiLinkLabel } from 'mastodon/features/emoji/emoji_mute_text';

// Profile note, follow message, and profile field values. Status bodies do
// not render through here. The stored emojify HTML is left unchanged; only
// this span's HTML is a viewer-specific projection. Link handlers are rebound
// after that projection changes. Emoji clicks stay on the span (capture, once)
// so a rules update cannot stack listeners or revive a removed image.

const messages = defineMessages({
  linkToAcct: { id: 'status.link_to_acct', defaultMessage: 'Link to @{acct}' },
  linkToCustomEmojiInLocal: { id: 'status.link_to_custom_emoji_in_local', defaultMessage: 'Link to :@{shortcode}:' },
  linkToCustomEmojiInRemote: { id: 'status.link_to_custom_emoji_in_remote', defaultMessage: 'Link to :@{shortcode}: in @{domain}' },
  postByAcct: { id: 'status.post_by_acct', defaultMessage: 'Post by @{acct}' },
});

@injectIntl
class Content extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    contentHtml: PropTypes.shape({
      __html: PropTypes.string.isRequired,
    }).isRequired,
    onClick: PropTypes.func,
    className: PropTypes.string,
    intl: PropTypes.object.isRequired,
    emojiMuteTextIndex: PropTypes.object,
  };

  handleEmojiClick = e => {
    const emoji = customEmojiTarget(e);

    if (!emoji || !this.clickNode || !this.clickNode.contains(emoji)) {
      return;
    }

    const shortcode = emoji.getAttribute('data-shortcode');
    const domain = emoji.getAttribute('data-domain');

    emoji.style.cursor = 'pointer';

    if (this.context.router) {
      e.preventDefault();
      e.stopPropagation();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  _updateContentLinks () {
    const { intl } = this.props;
    const node = this.node;

    if (!node) {
      return;
    }

    const links = node.querySelectorAll('a');

    for (var i = 0; i < links.length; ++i) {
      let link = links[i];
      if (link.classList.contains('status-link')) {
        continue;
      }
      link.classList.add('status-link');

      if (link.classList.contains('custom-emoji-url-link') && link.dataset.shortcode) {
        if (linkTargetEmojiRemains(link)) {
          if (link.dataset.domain) {
            link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInRemote, { shortcode: link.dataset.shortcode, domain: link.dataset.domain }));
          } else {
            link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInLocal, { shortcode: link.dataset.shortcode }));
          }
        } else {
          retainMutedEmojiLinkLabel(link);
        }
        link.addEventListener('click', this.onCustomEmojiUrlClick.bind(this, link.dataset.shortcode, link.dataset.domain), false);
      } else if ((link.classList.contains('account-url-link') || link.classList.contains('mention')) && link.dataset.accountId) {
        link.setAttribute('title', intl.formatMessage(messages.linkToAcct, { acct: link.dataset.accountAcct }));
        link.addEventListener('click', this.onAccountUrlClick.bind(this, link.dataset.accountId, link.dataset.path ?? '', link.dataset.accountActorType), false);
      } else if (link.classList.contains('status-url-link') && link.dataset.statusId) {
        link.setAttribute('title', intl.formatMessage(messages.postByAcct, { acct: link.dataset.statusAccountAcct }));
        link.addEventListener('click', this.onStatusUrlClick.bind(this, link.dataset.statusId, link.dataset.path ?? ''), false);
      } else if (link.textContent[0] === '#' || (link.previousSibling && link.previousSibling.textContent && link.previousSibling.textContent[link.previousSibling.textContent.length - 1] === '#')) {
        link.addEventListener('click', this.onHashtagClick.bind(this, link.text), false);
      } else {
        link.setAttribute('title', link.href);
        link.classList.add('unhandled-link');
      }

      link.setAttribute('target', '_blank');
      link.setAttribute('rel', 'noopener noreferrer');
    }
  }

  handleMouseEnter = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.style.cursor = 'pointer';
      emoji.src = emoji.getAttribute('data-original');
    }
  }

  handleMouseLeave = ({ currentTarget }) => {
    if (autoPlayEmoji) {
      return;
    }

    const emojis = currentTarget.querySelectorAll('.custom-emoji');

    for (var i = 0; i < emojis.length; i++) {
      let emoji = emojis[i];
      emoji.src = emoji.getAttribute('data-static');
    }
  }

  componentDidMount () {
    this._updateContentLinks();
  }

  componentDidUpdate () {
    this._updateContentLinks();
  }

  componentWillUnmount () {
    if (this.node) {
      this.node.removeEventListener('click', this.handleEmojiClick, true);
    }
  }

  onMentionClick = (mention, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/accounts/${mention.get('id')}`);
    }
  }

  onGroupMentionClick = (mention, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/timelines/groups/${mention.get('id')}`);
    }
  }

  onHashtagClick = (hashtag, e) => {
    hashtag = hashtag.replace(/^#/, '');

    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/timelines/tag/${hashtag}`);
    }
  }

  onAccountUrlClick = (accountId, path, accountActorType, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`${accountActorType === 'Group' ? '/timelines/groups/' : '/accounts/'}${accountId}${path}`);
    }
  }

  onStatusUrlClick = (statusId, path, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${statusId}${path}`);
    }
  }

  onCustomEmojiUrlClick = (shortcode, domain, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  handleMouseDown = (e) => {
    this.startXY = [e.clientX, e.clientY];
  }

  handleMouseUp = (e) => {
    if (!this.startXY) {
      return;
    }

    const [ startX, startY ] = this.startXY;
    const [ deltaX, deltaY ] = [Math.abs(e.clientX - startX), Math.abs(e.clientY - startY)];

    let element = e.target;
    while (element) {
      if (element.localName === 'button' || element.localName === 'a' || element.localName === 'label') {
        return;
      }
      element = element.parentNode;
    }

    if (deltaX + deltaY < 5 && e.button === 0 && this.props.onClick) {
      this.props.onClick();
    }

    this.startXY = null;
  }

  setRef = (node) => {
    if (node === this.node) {
      return;
    }

    if (this.node) {
      this.node.removeEventListener('click', this.handleEmojiClick, true);
    }

    this.node = node;
    this.clickNode = node;

    if (node) {
      node.addEventListener('click', this.handleEmojiClick, true);
    }
  }

  render () {
    const source = this.props.contentHtml && this.props.contentHtml.__html;
    const presented = replaceEmojiInDisplayHtml(source, this.props.emojiMuteTextIndex);
    const contentHtml = presented === source ? this.props.contentHtml : { __html: presented };

    return (
      <span
        ref={this.setRef}
        tabIndex='0'
        onMouseEnter={this.handleMouseEnter}
        onMouseLeave={this.handleMouseLeave}
        dangerouslySetInnerHTML={contentHtml}
        onMouseDown={this.props.onClick ? this.handleMouseDown : undefined}
        onMouseUp={this.props.onClick ? this.handleMouseUp : undefined}
      />
    );
  }

}

export default withEmojiMuteTextIndex(Content);
