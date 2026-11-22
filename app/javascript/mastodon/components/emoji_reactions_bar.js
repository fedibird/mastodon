import React, { Fragment } from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { List as ImmutableList, fromJS } from 'immutable';
import { barVisibleReaction } from 'mastodon/features/emoji/emoji_mute_projection';
import { emojiReactionsForStatus, emojiReactionAccountIds } from '../utils/emoji_reactions';

const shownReaction = (reaction, rules) => {
  const next = barVisibleReaction(reaction, rules);

  if (!next) {
    return null;
  }

  if (next === reaction) {
    return reaction;
  }

  return fromJS(next);
};
import TransitionMotion from 'react-motion/lib/TransitionMotion';
import { reduceMotion, me, hideReactionCounter, hideListOfEmojiReactionsToPosts } from 'mastodon/initial_state';
import { reduceMotionNow, watchReduceMotion } from 'mastodon/utils/appearance_preferences';
import spring from 'react-motion/lib/spring';
import EmojiReaction from './emoji_reactions';

const mapStateToProps = (state, { status }) => {
  const display = state.getIn(['emojiMutes', 'display']);
  const reactions = emojiReactionsForStatus(status);

  if (display === 'suppress') {
    return { emojiReactions: ImmutableList() };
  }

  if (display === 'show') {
    return { emojiReactions: reactions };
  }

  const rules = state.getIn(['emojiMutes', 'rules']);

  return {
    emojiReactions: reactions.map(reaction => shownReaction(reaction, rules)).filter(reaction => reaction && reaction.get('count') > 0),
    reactionRules: rules,
  };
};

const mergeProps = ({ emojiReactions, reactionRules }, dispatchProps, ownProps) => ({
  ...ownProps,
  ...dispatchProps,
  reactionRules: reactionRules || null,
  visibleReactions: emojiReactions.filter(x => x && typeof x.get === 'function' && x.get('count') > 0),
});

class EmojiReactionsBar extends ImmutablePureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map.isRequired,
    addEmojiReaction: PropTypes.func.isRequired,
    removeEmojiReaction: PropTypes.func.isRequired,
    visibleReactions: ImmutablePropTypes.list.isRequired,
    reactionRules: PropTypes.oneOfType([PropTypes.array, PropTypes.object]),
    reactionLimitReached: PropTypes.bool,
  };

  componentDidMount () {
    this.stopReduceMotion = watchReduceMotion(this, reduceMotion);
  }

  componentWillUnmount () {
    if (this.stopReduceMotion) {
      this.stopReduceMotion();
    }
  }

  willEnter () {
    return { scale: reduceMotionNow(reduceMotion) ? 1 : 0 };
  }

  willLeave () {
    return { scale: reduceMotionNow(reduceMotion) ? 0 : spring(0, { stiffness: 170, damping: 26 }) };
  }

  render () {
    const { status, addEmojiReaction, removeEmojiReaction, visibleReactions, reactionLimitReached, reactionRules } = this.props;

    if (visibleReactions.isEmpty() ) {
      return <Fragment />;
    }

    const styles = visibleReactions.map(emojiReaction => {
      const domain = emojiReaction.get('domain', '');

      return {
        key: `${emojiReaction.get('name')}${domain ? `@${domain}` : ''}`,
        data: {
          emojiReaction: emojiReaction,
          myReaction: emojiReactionAccountIds(emojiReaction).includes(me),
        },
        style: { scale: reduceMotionNow(reduceMotion) ? 1 : spring(1, { stiffness: 150, damping: 13 }) },
      };
    }).toArray();

    return (
      <TransitionMotion styles={styles} willEnter={this.willEnter} willLeave={this.willLeave}>
        {items => (
          <div className='reactions-bar emoji-reactions-bar'>
            {items.map(({ key, data, style }) => {
              const emojiReaction = shownReaction(data.emojiReaction, reactionRules);

              if (!emojiReaction) {
                return null;
              }

              return (
                <EmojiReaction
                  key={key}
                  emojiReaction={emojiReaction}
                  myReaction={emojiReactionAccountIds(emojiReaction).includes(me)}
                  style={{ transform: `scale(${style.scale})`, position: style.scale < 0.5 ? 'absolute' : 'static' }}
                  status={status}
                  addEmojiReaction={addEmojiReaction}
                  removeEmojiReaction={removeEmojiReaction}
                  reactionLimitReached={reactionLimitReached}
                  hideCount={hideReactionCounter}
                  hideAccountList={hideListOfEmojiReactionsToPosts}
                />
              );
            })}
          </div>
        )}
      </TransitionMotion>
    );
  }

}

export default connect(mapStateToProps, null, mergeProps)(EmojiReactionsBar);
