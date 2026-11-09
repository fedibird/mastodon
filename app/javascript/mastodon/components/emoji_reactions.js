import React, { Fragment } from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { injectIntl, defineMessages } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { List } from 'immutable';
import classNames from 'classnames';
import { fetchAccounts } from 'mastodon/actions/accounts';
import Emoji from './emoji';
import unicodeMapping from 'mastodon/features/emoji/emoji_unicode_mapping_light';
import AnimatedNumber from 'mastodon/components/animated_number';
import { disableReactions } from 'mastodon/initial_state';
import Overlay from 'react-overlays/Overlay';
import { isUserTouching } from 'mastodon/is_mobile';
import AccountPopup from 'mastodon/components/account_popup';
import { openEmojiActions } from 'mastodon/features/emoji/emoji_actions/bus';
import { datasetFromReference, referenceFromReaction } from 'mastodon/features/emoji/emoji_actions/reference';
import { attachLongPressGesture } from 'mastodon/features/emoji/long_press';

const messages = defineMessages({
  manage: { id: 'emoji_actions.manage', defaultMessage: 'Emoji actions' },
});

const getFilteredEmojiReaction = (emojiReaction, relationships) => {
  let filteredEmojiReaction = emojiReaction.update('account_ids', accountIds => accountIds.filterNot( accountId => {
    const relationship = relationships.get(accountId);
    return relationship?.get('blocking') || relationship?.get('blocked_by') || relationship?.get('domain_blocking') || relationship?.get('muting');
  }));

  const count = filteredEmojiReaction.get('account_ids').size;

  if (count > 0) {
    return filteredEmojiReaction.set('count', count);
  } else {
    return null;
  }
};

const mapStateToProps = (state, { emojiReaction }) => {
  const relationships = new Map();
  emojiReaction.get('account_ids').forEach(accountId => relationships.set(accountId, state.getIn(['relationships', accountId])));

  return {
    emojiReaction,
    relationships,
    updateCount: state.getIn(['relationships', 'updateCount']),
  };
};

const mergeProps = ({ emojiReaction, relationships }, dispatchProps, ownProps) => ({
  ...ownProps,
  ...dispatchProps,
  emojiReaction: getFilteredEmojiReaction(emojiReaction, relationships),
});

class EmojiReaction extends ImmutablePureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    status: ImmutablePropTypes.map.isRequired,
    emojiReaction: ImmutablePropTypes.map,
    myReaction: PropTypes.bool.isRequired,
    addEmojiReaction: PropTypes.func.isRequired,
    removeEmojiReaction: PropTypes.func.isRequired,
    style: PropTypes.object,
    reactionLimitReached: PropTypes.bool,
    hideCount: PropTypes.bool,
    hideAccountList: PropTypes.bool,
  };

  state = {
    hovered: false,
    fetched: false,
  };

  reactionContext = () => {
    const { emojiReaction, myReaction, reactionLimitReached } = this.props;

    if (!emojiReaction) {
      return null;
    }

    return {
      name: emojiReaction.get('name'),
      domain: emojiReaction.get('domain', null),
      url: emojiReaction.get('url', null),
      static_url: emojiReaction.get('static_url', null),
      my_reaction: myReaction,
      reaction_limit_reached: Boolean(reactionLimitReached),
      disabled: Boolean(disableReactions),
    };
  };

  handleClick = () => {
    const { emojiReaction, status, addEmojiReaction, removeEmojiReaction, myReaction, reactionLimitReached } = this.props;

    // Keep the chip pointer-enabled so long-press / context menu still open
    // when reactions are at the limit or globally disabled.
    if (disableReactions) {
      return;
    }

    if (myReaction) {
      removeEmojiReaction(status, emojiReaction.get('name'));
    } else if (!reactionLimitReached) {
      addEmojiReaction(status, emojiReaction.get('name'), emojiReaction.get('domain', null), emojiReaction.get('url', null), emojiReaction.get('static_url', null));
    }
  };

  openActions = (anchor, event) => {
    const { emojiReaction, status } = this.props;
    const reference = referenceFromReaction(emojiReaction);

    if (!reference) {
      return;
    }

    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }

    openEmojiActions(reference, {
      anchor: anchor || null,
      status_id: status.get('id'),
      account_id: status.get('account'),
      source: 'reaction',
      reaction: this.reactionContext(),
    });
  };

  handleOpenActions = event => {
    this.openActions(event.currentTarget, event);
  };

  handleMouseEnter = ({ target }) => {
    const { top } = target.getBoundingClientRect();
    const { dispatch, emojiReaction } = this.props;

    if (!this.state.fetched) {
      dispatch(fetchAccounts(emojiReaction.get('account_ids')));
    }

    this.setState({
      hovered: true,
      fetched: true,
      placement: top * 2 < innerHeight ? 'bottom' : 'top',
    });
  };

  handleMouseLeave = () => {
    this.setState({
      hovered: false,
    });
  };

  setTargetRef = c => {
    this.target = c;
  };

  setChipRef = node => {
    if (this.detachLongPress) {
      this.detachLongPress();
      this.detachLongPress = null;
    }

    this.chip = node;

    if (node) {
      this.detachLongPress = attachLongPressGesture(node, {
        onLongPress: event => {
          this.openActions(node, event);
        },
      });
    }
  };

  findTarget = () => {
    return this.target;
  };

  componentDidMount () {
    this.target?.addEventListener('mouseenter', this.handleMouseEnter, { capture: true });
    this.target?.addEventListener('mouseleave', this.handleMouseLeave, false);
  }

  componentWillUnmount () {
    this.target?.removeEventListener('mouseenter', this.handleMouseEnter, { capture: true });
    this.target?.removeEventListener('mouseleave', this.handleMouseLeave, false);

    if (this.detachLongPress) {
      this.detachLongPress();
      this.detachLongPress = null;
    }
  }

  render () {
    const { intl, style, status, emojiReaction, myReaction, reactionLimitReached, hideCount, hideAccountList } = this.props;

    if (!emojiReaction) {
      return <Fragment />;
    }

    let shortCode = emojiReaction.get('name');

    if (unicodeMapping[shortCode]) {
      shortCode = unicodeMapping[shortCode].shortCode;
    }

    const reference = referenceFromReaction(emojiReaction);
    const actionDataset = datasetFromReference(reference);
    const reaction = this.reactionContext();
    const actionProps = {
      'data-emoji-actions': '1',
      'data-emoji-source': 'reaction',
      'data-emoji-status-id': status.get('id'),
      'data-emoji-account-id': status.get('account'),
      'data-emoji-reaction-name': reaction.name,
    };

    if (reaction.domain) actionProps['data-emoji-reaction-domain'] = reaction.domain;
    if (reaction.url) actionProps['data-emoji-reaction-url'] = reaction.url;
    if (reaction.static_url) actionProps['data-emoji-reaction-static-url'] = reaction.static_url;
    if (reaction.my_reaction) actionProps['data-emoji-my-reaction'] = '1';
    if (reaction.reaction_limit_reached) actionProps['data-emoji-reaction-limit-reached'] = '1';
    if (reaction.disabled) actionProps['data-emoji-reaction-disabled'] = '1';

    if (actionDataset.emojiKind) actionProps['data-emoji-kind'] = actionDataset.emojiKind;
    if (actionDataset.emojiNative) actionProps['data-emoji-native'] = actionDataset.emojiNative;
    if (actionDataset.emojiScope) actionProps['data-emoji-scope'] = actionDataset.emojiScope;
    if (actionDataset.emojiCustomEmojiId) actionProps['data-emoji-custom-emoji-id'] = actionDataset.emojiCustomEmojiId;
    if (actionDataset.emojiDomain) actionProps['data-emoji-domain'] = actionDataset.emojiDomain;
    if (actionDataset.emojiShortcode) actionProps['data-emoji-shortcode'] = actionDataset.emojiShortcode;

    return (
      <Fragment>
        <div className='reactions-bar__item-wrapper' ref={this.setTargetRef}>
          <button
            ref={this.setChipRef}
            type='button'
            className={classNames('reactions-bar__item', {
              active: myReaction,
              disabled: disableReactions || (!myReaction && reactionLimitReached),
            })}
            aria-disabled={disableReactions || (!myReaction && reactionLimitReached) ? 'true' : undefined}
            onClick={this.handleClick}
            title={`:${shortCode}:`}
            style={style}
            {...actionProps}
          >
            <span className='reactions-bar__item__emoji'><Emoji className='reaction' hovered={this.state.hovered} emoji={emojiReaction.get('name')} url={emojiReaction.get('url')} static_url={emojiReaction.get('static_url')} /></span>
            {!hideCount && <span className='reactions-bar__item__count'><AnimatedNumber value={emojiReaction.get('count')} /></span>}
          </button>
          {reference && (
            <button
              type='button'
              className='emoji-actions-trigger reactions-bar__item-actions'
              aria-label={intl.formatMessage(messages.manage)}
              title={intl.formatMessage(messages.manage)}
              onClick={this.handleOpenActions}
            >
              ⋯
            </button>
          )}
        </div>
        {!hideAccountList && !isUserTouching() &&
        <Overlay show={this.state.hovered} offset={[5, 5]} placement={this.state.placement} target={this.findTarget}>
          {({ props, arrowProps, placement }) => (
            <div {...props}>
              <div className={`dropdown-menu dropdown-animation account-popup ${placement}`}>
                <div className={`dropdown-menu__arrow account-popup ${placement}`} {...arrowProps} />
                <AccountPopup accountIds={emojiReaction.get('account_ids', List())} />
              </div>
            </div>
          )}
        </Overlay>
        }
      </Fragment>
    );
  };

}

export default injectIntl(connect(mapStateToProps, null, mergeProps)(EmojiReaction));
