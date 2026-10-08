import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { defineMessages, injectIntl } from 'react-intl';
import classNames from 'classnames';
import { createCapabilityNoticeIsWarning } from '../../../posting_context/create_capability';

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
  createAllowed: { id: 'compose_form.posting_context.create.allowed', defaultMessage: 'Create permission confirmed' },
  createAllowedCompatibility: { id: 'compose_form.posting_context.create.allowed_compatibility', defaultMessage: 'Create permission confirmed · compatibility method' },
  createUnknownCompatibility: { id: 'compose_form.posting_context.create.unknown_compatibility', defaultMessage: 'Create permission not confirmed · compatibility method' },
  createRefreshing: { id: 'compose_form.posting_context.create.refreshing', defaultMessage: 'Rechecking create permission' },
  createRefreshFailed: { id: 'compose_form.posting_context.create.refresh_failed', defaultMessage: 'Latest create permission could not be confirmed' },
  createAllowedUnsupported: { id: 'compose_form.posting_context.create.allowed_unsupported', defaultMessage: 'Create permission has supporting evidence, but this posting method is not supported' },
  createVia: { id: 'compose_form.posting_context.create.via', defaultMessage: 'Evidence: {viaRelationship}' },
  createViaNone: { id: 'compose_form.posting_context.create.via_none', defaultMessage: 'No affiliation is required' },
  blockedUnsupported: { id: 'compose_form.posting_context.blocked.unsupported', defaultMessage: 'This group\'s posting method is not supported' },
  blockedUnresolved: { id: 'compose_form.posting_context.blocked.unresolved', defaultMessage: 'Group posting context is not available' },
  blockedMismatch: { id: 'compose_form.posting_context.blocked.mismatch', defaultMessage: 'The posting target does not match this composer' },
  blockedCompliance: { id: 'compose_form.posting_context.blocked.compliance', defaultMessage: 'Posting conditions are not met' },
  blockedDetails: { id: 'compose_form.posting_context.blocked.details', defaultMessage: 'Show details' },
});

const createNoticeMessages = {
  allowed: messages.createAllowed,
  allowed_compatibility: messages.createAllowedCompatibility,
  unknown_compatibility: messages.createUnknownCompatibility,
  refreshing: messages.createRefreshing,
  refresh_failed: messages.createRefreshFailed,
  allowed_unsupported: messages.createAllowedUnsupported,
  unsupported: messages.blockedUnsupported,
  unresolved: messages.blockedUnresolved,
  mismatch: messages.blockedMismatch,
};

export const postingContextCapabilityMessages = messages;

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
    suppressed: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleClick = () => {
    this.props.onToggle(this.props.normalizedName);
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
    createNotice: PropTypes.string,
    viaRelationship: PropTypes.string,
    onToggle: PropTypes.func.isRequired,
  };

  viaTitle () {
    const { intl, viaRelationship, createNotice } = this.props;
    const confirmed = createNotice === 'allowed' || createNotice === 'allowed_compatibility' || createNotice === 'allowed_unsupported';

    if (!confirmed || !viaRelationship) {
      return undefined;
    }

    if (viaRelationship === 'none') {
      return intl.formatMessage(messages.createViaNone);
    }

    return intl.formatMessage(messages.createVia, { viaRelationship });
  }

  render () {
    const { intl, hashtags, suppressedHashtags, mentions, audience, visibility, followingAccounts, createNotice, onToggle } = this.props;
    const hasHashtags = Boolean(hashtags && !hashtags.isEmpty());
    const requiredMentions = mentions ? mentions.filter(mention => mention.get('enforcement') === 'required' && mention.get('acct')) : null;
    const hasMentions = Boolean(requiredMentions && !requiredMentions.isEmpty());
    const audienceAcct = audience && audience.get('enforcement') === 'required' ? audience.get('acct') : null;
    const showAudience = Boolean(audienceAcct);
    const allowed = visibility && visibility.allowed;
    const showVisibility = Array.isArray(allowed) && allowed.includes('public') && allowed.includes('unlisted');
    const hasFollows = Boolean(followingAccounts && followingAccounts.length > 0);
    const createMessage = createNoticeMessages[createNotice];

    if (!hasHashtags && !hasMentions && !showAudience && !showVisibility && !hasFollows && !createMessage) {
      return null;
    }

    return (
      <div className='compose-form__posting-context'>
        <span className='compose-form__posting-context-label'>
          {intl.formatMessage(messages.label)}
        </span>
        {createMessage && (
          <span
            className={classNames('compose-form__posting-context-create', {
              'compose-form__posting-context-create--blocked': createCapabilityNoticeIsWarning(createNotice),
            })}
            title={this.viaTitle()}
          >
            {intl.formatMessage(createMessage)}
          </span>
        )}
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

          return (
            <ManagedHashtagButton
              key={normalizedName}
              name={tag.get('name')}
              normalizedName={normalizedName}
              suppressed={Boolean(suppressedHashtags && suppressedHashtags.includes(normalizedName))}
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
