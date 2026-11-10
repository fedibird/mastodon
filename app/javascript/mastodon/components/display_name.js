import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { autoPlayEmoji } from 'mastodon/initial_state';
import EmojiMutedHtml, { customEmojiTarget } from 'mastodon/components/emoji_muted_html';

export default class DisplayName extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    account: ImmutablePropTypes.map.isRequired,
    others: ImmutablePropTypes.list,
    localDomain: PropTypes.string,
  };

  componentDidMount () {
    this.clickNode = this.node;

    if (this.clickNode) {
      this.clickNode.addEventListener('click', this.handleEmojiClick, true);
    }
  }

  componentWillUnmount () {
    if (this.clickNode) {
      this.clickNode.removeEventListener('click', this.handleEmojiClick, true);
    }
  }

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

  setRef = (c) => {
    this.node = c;
  }

  render () {
    const { others, localDomain } = this.props;

    let displayName, suffix, account;

    if (others && others.size > 1) {
      displayName = others.take(2).map(a => <bdi key={a.get('id')}><EmojiMutedHtml tag='strong' className='display-name__html' html={a.get('display_name_html')} /></bdi>).reduce((prev, cur) => [prev, ', ', cur]);

      if (others.size - 2 > 0) {
        suffix = `+${others.size - 2}`;
      }
    } else {
      if (others && others.size > 0) {
        account = others.first();
      } else {
        account = this.props.account;
      }

      let acct = account.get('acct');

      if (acct.indexOf('@') === -1 && localDomain) {
        acct = `${acct}@${localDomain}`;
      }

      displayName = <bdi><EmojiMutedHtml tag='strong' className='display-name__html' html={account.get('display_name_html')} /></bdi>;
      suffix      = <span className='display-name__account'>@{acct}</span>;
    }

    return (
      <span className='display-name' ref={this.setRef} onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave}>
        {displayName} {suffix}
      </span>
    );
  }

}
