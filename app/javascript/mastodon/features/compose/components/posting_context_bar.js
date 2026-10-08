import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';

const messages = defineMessages({
  label: { id: 'compose_form.posting_context', defaultMessage: 'Posting context' },
  include: { id: 'compose_form.posting_context.include', defaultMessage: 'Include #{hashtag}' },
  exclude: { id: 'compose_form.posting_context.exclude', defaultMessage: 'Do not add #{hashtag}' },
  mentionRequired: { id: 'compose_form.posting_context.mention_required', defaultMessage: 'Required mention: @{acct}' },
  audienceGroup: { id: 'compose_form.posting_context.audience_group', defaultMessage: 'Posting to group: @{acct}' },
  visibilityPublicUnlisted: { id: 'compose_form.posting_context.visibility.public_unlisted', defaultMessage: 'Visibility: Public or Unlisted' },
  followSatisfied: { id: 'compose_form.posting_context.follow.satisfied', defaultMessage: '✓ Following @{acct}' },
  followUnknown: { id: 'compose_form.posting_context.follow.unknown', defaultMessage: 'Checking follow status for @{acct}…' },
  followRequested: { id: 'compose_form.posting_context.follow.requested', defaultMessage: 'Follow request to @{acct} is pending' },
  followNotFollowing: { id: 'compose_form.posting_context.follow.not_following', defaultMessage: 'Follow @{acct} to post in this group' },
});

const followMessages = {
  satisfied: messages.followSatisfied,
  unknown: messages.followUnknown,
  requested: messages.followRequested,
  not_following: messages.followNotFollowing,
};

class ManagedHashtagButton extends React.PureComponent {

  static propTypes = {
    name: PropTypes.string.isRequired,
    normalizedName: PropTypes.string.isRequired,
    origin: PropTypes.string,
    suppressed: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = () => {
    this.props.onToggle(this.props.normalizedName, this.props.origin);
  }

  render () {
    const { intl, name, suppressed } = this.props;
    const hashtag = name.replace(/^[#＃]+/u, '');
    const action = intl.formatMessage(suppressed ? messages.include : messages.exclude, { hashtag });

    return (
      <button
        type='button'
        className={classNames('compose-form__posting-context-tag', {
          'compose-form__posting-context-tag--suppressed': suppressed,
        })}
        title={action}
        aria-label={action}
        aria-pressed={!suppressed}
        onClick={this.handleClick}
      >
        {`#${hashtag}`}
        <span aria-hidden='true'>{suppressed ? '＋' : '×'}</span>
      </button>
    );
  }

}

class PostingContextBar extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    hashtags: ImmutablePropTypes.list,
    suppressedHashtags: ImmutablePropTypes.set,
    mentions: ImmutablePropTypes.list,
    audience: ImmutablePropTypes.map,
    visibility: PropTypes.shape({
      valid: PropTypes.bool,
      allowed: PropTypes.array,
    }),
    followingAccounts: PropTypes.array,
    onToggle: PropTypes.func.isRequired,
  };

  render () {
    const { intl, hashtags, suppressedHashtags, mentions, audience, visibility, followingAccounts, onToggle } = this.props;
    const hasHashtags = Boolean(hashtags && !hashtags.isEmpty());
    const requiredMentions = mentions ? mentions.filter(mention => mention.get('enforcement') === 'required' && mention.get('acct')) : null;
    const hasMentions = Boolean(requiredMentions && !requiredMentions.isEmpty());
    const audienceAcct = audience && audience.get('enforcement') === 'required' ? audience.get('acct') : null;
    const showAudience = Boolean(audienceAcct);
    const allowed = visibility && visibility.allowed;
    const showVisibility = Array.isArray(allowed) && allowed.includes('public') && allowed.includes('unlisted');
    const hasFollows = Boolean(followingAccounts && followingAccounts.length > 0);

    if (!hasHashtags && !hasMentions && !showAudience && !showVisibility && !hasFollows) {
      return null;
    }

    return (
      <div className='compose-form__posting-context'>
        <span className='compose-form__posting-context-label'>
          {intl.formatMessage(messages.label)}
        </span>
        {showAudience && (
          <span className='compose-form__posting-context-audience'>
            {intl.formatMessage(messages.audienceGroup, { acct: audienceAcct })}
          </span>
        )}
        {hasMentions && requiredMentions.map(mention => (
          <span key={mention.get('accountId')} className='compose-form__posting-context-mention'>
            {intl.formatMessage(messages.mentionRequired, { acct: mention.get('acct') })}
          </span>
        ))}
        {showVisibility && (
          <span className={classNames('compose-form__posting-context-visibility', { 'compose-form__posting-context-warning': !visibility.valid })}>
            {intl.formatMessage(messages.visibilityPublicUnlisted)}
          </span>
        )}
        {hasFollows && followingAccounts.map(account => (
          <span key={account.accountId} className={classNames('compose-form__posting-context-follow', { 'compose-form__posting-context-warning': account.status !== 'satisfied' })}>
            {intl.formatMessage(followMessages[account.status] || messages.followUnknown, { acct: account.acct })}
          </span>
        ))}
        {hasHashtags && hashtags.map(tag => {
          const normalizedName = tag.get('normalizedName');
          const origin = tag.get('origin');
          const suppressed = tag.has('suppressed') ? tag.get('suppressed') : Boolean(suppressedHashtags && suppressedHashtags.includes(normalizedName));
          const key = `${origin || 'context'}:${normalizedName}`;

          if (tag.get('enforcement') === 'required') {
            return (
              <span key={key} className='compose-form__posting-context-tag compose-form__posting-context-tag--required'>
                {`#${tag.get('name')}`}
              </span>
            );
          }

          return (
            <ManagedHashtagButton
              key={key}
              name={tag.get('name')}
              normalizedName={normalizedName}
              origin={origin}
              suppressed={suppressed}
              onToggle={onToggle}
              intl={intl}
            />
          );
        })}
      </div>
    );
  }

}

export default injectIntl(PostingContextBar);
