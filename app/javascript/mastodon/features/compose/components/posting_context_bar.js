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
  visibilityPublicOnly: { id: 'compose_form.posting_context.visibility.public_only', defaultMessage: 'This destination supports public posts only' },
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
  recheck: { id: 'compose_form.posting_context.revalidation.action', defaultMessage: 'Recheck' },
  revalidationRunning: { id: 'compose_form.posting_context.revalidation.running', defaultMessage: 'Rechecking create permission' },
  revalidationPartial: { id: 'compose_form.posting_context.revalidation.partial', defaultMessage: 'Some information could not be updated' },
  revalidationFailed: { id: 'compose_form.posting_context.revalidation.failed', defaultMessage: 'Create permission could not be rechecked' },
  revalidationStale: { id: 'compose_form.posting_context.revalidation.stale', defaultMessage: 'Permission information is out of date' },
  revalidationRateLimited: { id: 'compose_form.posting_context.revalidation.rate_limited', defaultMessage: 'Wait before rechecking create permission' },
  revalidationResume: { id: 'compose_form.posting_context.revalidation.resume', defaultMessage: 'Check status again' },
  revalidationInterrupted: { id: 'compose_form.posting_context.revalidation.interrupted', defaultMessage: 'Status could not be checked' },
  revalidationTimedOut: { id: 'compose_form.posting_context.revalidation.timed_out', defaultMessage: 'Recheck may still be running on the server' },
  revalidationDetail: { id: 'compose_form.posting_context.revalidation.detail', defaultMessage: 'Actor: {actor} / Affiliations: {affiliations}' },
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

const revalidationMessages = {
  running: messages.revalidationRunning,
  partial: messages.revalidationPartial,
  failed: messages.revalidationFailed,
  stale: messages.revalidationStale,
  rate_limited: messages.revalidationRateLimited,
  interrupted: messages.revalidationInterrupted,
  timed_out: messages.revalidationTimedOut,
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
    createNotice: PropTypes.string,
    viaRelationship: PropTypes.string,
    canRecheck: PropTypes.bool,
    revalidationNotice: PropTypes.string,
    revalidationActor: PropTypes.string,
    revalidationAffiliations: PropTypes.string,
    revalidationAccountId: PropTypes.string,
    revalidationExplicit: PropTypes.bool,
    onToggle: PropTypes.func.isRequired,
    onRecheck: PropTypes.func,
    onRefreshStatus: PropTypes.func,
    onWatch: PropTypes.func,
  };

  componentDidMount () {
    this.syncWatch();
  }

  componentDidUpdate (prevProps) {
    if (prevProps.revalidationAccountId !== this.props.revalidationAccountId) {
      this.releaseWatch();
    }

    this.syncWatch();
  }

  componentWillUnmount () {
    this.releaseWatch();
  }

  releaseWatch () {
    if (this.release) {
      this.release();
      this.release = null;
    }
  }

  syncWatch () {
    const active = this.props.revalidationExplicit && this.props.revalidationNotice === 'running';

    if (active && !this.release && this.props.onWatch) {
      this.release = this.props.onWatch();
    } else if (!active) {
      this.releaseWatch();
    }
  }

  handleRecheck = () => {
    if (this.props.onRecheck) {
      this.props.onRecheck();
    }
  }

  handleRefreshStatus = () => {
    if (this.props.onRefreshStatus) {
      this.props.onRefreshStatus();
    }
  }

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
    const { intl, hashtags, suppressedHashtags, mentions, audience, visibility, followingAccounts, createNotice, canRecheck, revalidationNotice, revalidationActor, revalidationAffiliations, onToggle } = this.props;
    const hasHashtags = Boolean(hashtags && !hashtags.isEmpty());
    const requiredMentions = mentions ? mentions.filter(mention => mention.get('enforcement') === 'required' && mention.get('acct')) : null;
    const hasMentions = Boolean(requiredMentions && !requiredMentions.isEmpty());
    const audienceAcct = audience && audience.get('enforcement') === 'required' ? audience.get('acct') : null;
    const showAudience = Boolean(audienceAcct);
    const allowed = visibility && visibility.allowed;
    const showVisibility = Array.isArray(allowed) && allowed.includes('public') && allowed.includes('unlisted');
    const showPublicOnly = Array.isArray(allowed) && allowed.length === 1 && allowed[0] === 'public';
    const hasFollows = Boolean(followingAccounts && followingAccounts.length > 0);
    const createMessage = createNoticeMessages[createNotice];
    const revalidationMessage = revalidationMessages[revalidationNotice];
    const showResume = revalidationNotice === 'interrupted' || revalidationNotice === 'timed_out';
    const showRecheck = Boolean(canRecheck && !showResume && revalidationNotice !== 'running');

    if (!hasHashtags && !hasMentions && !showAudience && !showVisibility && !showPublicOnly && !hasFollows && !createMessage && !showRecheck && !showResume && !revalidationMessage) {
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
        {revalidationMessage && (
          <span
            className='compose-form__posting-context-revalidation'
            title={revalidationActor || revalidationAffiliations ? intl.formatMessage(messages.revalidationDetail, {
              actor: revalidationActor || 'unavailable',
              affiliations: revalidationAffiliations || 'unavailable',
            }) : undefined}
          >
            {intl.formatMessage(revalidationMessage)}
          </span>
        )}
        {showRecheck && (
          <button type='button' className='compose-form__posting-context-recheck' onClick={this.handleRecheck}>
            {intl.formatMessage(messages.recheck)}
          </button>
        )}
        {showResume && (
          <button type='button' className='compose-form__posting-context-recheck' onClick={this.handleRefreshStatus}>
            {intl.formatMessage(messages.revalidationResume)}
          </button>
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
        {showPublicOnly && (
          <span className={classNames('compose-form__posting-context-visibility', { 'compose-form__posting-context-warning': !visibility.valid })}>
            {intl.formatMessage(messages.visibilityPublicOnly)}
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
