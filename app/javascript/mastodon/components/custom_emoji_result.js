// @ts-check
import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { injectIntl, defineMessages, FormattedMessage } from 'react-intl';
import Emoji from './emoji';
import { attachInlineEmojiMenus, handleInlineEmojiClick, openInlineEmojiMenu } from 'mastodon/features/emoji/emoji_actions/inline_emoji';

const messages = defineMessages({
  linkToAcct: { id: 'status.link_to_acct', defaultMessage: 'Link to @{acct}' },
  linkToCustomEmojiInLocal: { id: 'status.link_to_custom_emoji_in_local', defaultMessage: 'Link to :@{shortcode}:' },
  linkToCustomEmojiInRemote: { id: 'status.link_to_custom_emoji_in_remote', defaultMessage: 'Link to :@{shortcode}: in @{domain}' },
  postByAcct: { id: 'status.post_by_acct', defaultMessage: 'Post by @{acct}' },
});

const mapStateToProps = (state, { shortcode_with_domain }) => ({
  custom_emoji: state.getIn(['custom_emojis_detail', shortcode_with_domain]),
});

class CustomEmojiResult extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    shortcode_with_domain: PropTypes.string.isRequired,
    custom_emoji: ImmutablePropTypes.map.isRequired,
    intl: PropTypes.object.isRequired,
  };

  state = {
    hovered: false,
  };

  handleEmojiClick = e => {
    handleInlineEmojiClick(e, e.currentTarget, this.context.router, { source: 'inline_emoji_search' });
  }

  handleMouseEnter = () => this.setState({ hovered: true });
  handleMouseLeave = () => this.setState({ hovered: false });

  _updateLinks () {
    const { intl } = this.props;
    const node = this.node;

    if (!node) {
      return;
    }

    const reference_link = node.querySelector('.reference-link-inline > a');
    if (reference_link && reference_link?.dataset?.statusId && !reference_link.hasReferenceClick ) {
      reference_link.addEventListener('click', this.onReferenceLinkClick.bind(this, reference_link.dataset.statusId), false);
      reference_link.setAttribute('target', '_blank');
      reference_link.setAttribute('rel', 'noopener noreferrer');
      reference_link.hasReferenceClick = true;
    }

    const links = node.querySelectorAll(':not(.reference-link-inline) > a');

    for (var i = 0; i < links.length; ++i) {
      let link = links[i];
      if (link.classList.contains('status-link')) {
        continue;
      }
      link.classList.add('status-link');

      if (link.classList.contains('custom-emoji-url-link') && link.dataset.shortcode) {
        if (link.dataset.domain) {
          link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInRemote, { shortcode: link.dataset.shortcode, domain: link.dataset.domain }));
        } else {
          link.setAttribute('title', intl.formatMessage(messages.linkToCustomEmojiInLocal, { shortcode: link.dataset.shortcode }));
        }
        link.addEventListener('click', this.onCustomEmojiUrlClick.bind(this, link.dataset.shortcode, link.dataset.domain), false);
      } else if (link.textContent[0] === '#' || (link.previousSibling && link.previousSibling.textContent && link.previousSibling.textContent[link.previousSibling.textContent.length - 1] === '#')) {
        link.addEventListener('click', this.onHashtagClick.bind(this, link.text), false);
      } else if (link.classList.contains('account-url-link')) {
        link.setAttribute('title', intl.formatMessage(messages.linkToAcct, { acct: link.dataset.accountAcct }));
        link.addEventListener('click', this.onAccountUrlClick.bind(this, link.dataset.accountId, link.dataset.path ?? '', link.dataset.accountActorType), false);
      } else if (link.classList.contains('status-url-link')) {
        link.setAttribute('title', intl.formatMessage(messages.postByAcct, { acct: link.dataset.statusAccountAcct }));
        link.addEventListener('click', this.onStatusUrlClick.bind(this, link.dataset.statusId, link.dataset.path ?? ''), false);
      } else {
        link.setAttribute('title', link.href);
        link.classList.add('unhandled-link');
      }

      link.setAttribute('target', '_blank');
      link.setAttribute('rel', 'noopener noreferrer');
    }
  }

  setRef = (c) => {
    this.node = c;
  }

  componentDidMount () {
    this._updateLinks();
    this.updateEmojiMenu();
  }

  componentDidUpdate () {
    this._updateLinks();
    this.updateEmojiMenu();
  }

  componentWillUnmount () {
    this.detachInlineEmojiMenus?.();
  }

  setEmojiRef = node => {
    this.emojiRoot = node;
  };

  updateEmojiMenu = () => {
    this.detachInlineEmojiMenus?.();
    this.detachInlineEmojiMenus = attachInlineEmojiMenus(this.emojiRoot, { source: 'inline_emoji_search' });
  };

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
      this.context.router.history.push(`${accountActorType == 'Group' ? '/timelines/groups/' : '/accounts/'}${accountId}${path}`);
    }
  }

  onStatusUrlClick = (statusId, path, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${statusId}${path}`);
    }
  }

  onReferenceLinkClick = (statusId, e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${statusId}/references`);
    }
  }

  onCustomEmojiUrlClick = (shortcode, domain, e) => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey) return;
    if (openInlineEmojiMenu(e.currentTarget, { source: 'inline_emoji_search' })) {
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (this.context.router) {
      e.preventDefault();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  render () {
    const { custom_emoji } = this.props;

    if (!custom_emoji) {
      return null;
    }

    const shortcode = custom_emoji.get('shortcode');
    const domain = custom_emoji.get('domain');    
    const title = custom_emoji.get('alternate_name') ?? shortcode;
    const summary = custom_emoji.get('summary') ?? custom_emoji.get('misskey_license');

    return (
      <div className='custom-emoji__result'>
        <div className='custom-emoji__image' ref={this.setEmojiRef} onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
          <Emoji emoji={shortcode} domain={domain} hovered={this.state.hovered} title={title} url={custom_emoji.get('url')} static_url={custom_emoji.get('static_url')} onClick={this.handleEmojiClick}/>
        </div>
        <div className='custom-emoji__shortcode'>:{shortcode}:{domain && <span className='custom-emoji__domain_part'>{domain}</span>}</div>
        {summary && 
          <div className='custom-emoji__summary_wrapper' ref={this.setRef}>
            <div className='custom-emoji__label'><FormattedMessage id='search_results.custom_emojis.summary' defaultMessage='License summary' /></div>
            <div className='custom-emoji__summary' dangerouslySetInnerHTML={{ __html: summary}} />
          </div>
        }
      </div>
    );
  
  }

}

export default injectIntl(connect(mapStateToProps)(CustomEmojiResult));
