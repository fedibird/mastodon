import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import Warning from '../components/warning';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import { me, maxAttachments } from '../../../initial_state';
import { cancelScheduledStatusCompose } from '../../../actions/compose';
import Icon from 'mastodon/components/icon';
import IconButton from 'mastodon/components/icon_button';

const buildHashtagRE = () => {
  try {
    const HASHTAG_SEPARATORS = '_\\u00b7\\u200c';
    const ALPHA = '\\p{L}\\p{M}';
    const WORD = '\\p{L}\\p{M}\\p{N}\\p{Pc}';
    return new RegExp(
      '(?:^|[^\\/\\)\\w])#((' +
      '[' + WORD + '_]' +
      '[' + WORD + HASHTAG_SEPARATORS + ']*' +
      '[' + ALPHA + HASHTAG_SEPARATORS + ']' +
      '[' + WORD + HASHTAG_SEPARATORS +']*' +
      '[' + WORD + '_]' +
      ')|(' +
      '[' + WORD + '_]*' +
      '[' + ALPHA + ']' +
      '[' + WORD + '_]*' +
      '))', 'iu',
    );
  } catch {
    return /(?:^|[^\/\)\w])#(\w*[a-zA-Z·]\w*)/i;
  }
};

const APPROX_HASHTAG_RE = buildHashtagRE();

const mapStateToProps = state => ({
  needsLockWarning: state.getIn(['compose', 'privacy']) === 'private' && !state.getIn(['accounts', me, 'locked']),
  hashtagWarning: !['public', 'personal'].includes(state.getIn(['compose', 'privacy'])) && APPROX_HASHTAG_RE.test(state.getIn(['compose', 'text'])),
  directMessageWarning: state.getIn(['compose', 'privacy']) === 'direct',
  limitedMessageWarning: state.getIn(['compose', 'privacy']) === 'limited',
  mutualMessageWarning: state.getIn(['compose', 'privacy']) === 'mutual',
  personalMessageWarning: state.getIn(['compose', 'privacy']) === 'personal',
  isScheduledStatusEditting: !!state.getIn(['compose', 'scheduled_status_id']),
  isEditing: !!state.getIn(['compose', 'id']),
  attachmentsWarning: !['public', 'unlisted', 'personal'].includes(state.getIn(['compose', 'privacy'])) && state.getIn(['compose', 'media_attachments']).size > 4,
});

const mapDispatchToProps = dispatch => ({

  onCancel () {
    dispatch(cancelScheduledStatusCompose());
  },

});

const ScheduledStatusWarningWrapper = ({ isScheduledStatusEditting, isEditing, onCancel }) => {
  if (isEditing || !isScheduledStatusEditting) {
    return null;
  }

  return (
    <div className='scheduled-status-warning-indicator'>
      <div className='scheduled-status-warning-indicator__cancel'><IconButton title='Cancel' icon='times' onClick={onCancel} inverted /></div>
      <div className='scheduled-status-warning-indicator__content translate'>
        <Icon id='clock-o' fixedWidth /><FormattedMessage id='compose_form.scheduled_status_warning' defaultMessage='Scheduled post editing in progress.' />
      </div>
    </div>
  );
};

ScheduledStatusWarningWrapper.propTypes = {
  isScheduledStatusEditting: PropTypes.bool,
  isEditing: PropTypes.bool,
  onCancel: PropTypes.func.isRequired,
};

const AttachmentWarningWrapper = ({ attachmentsWarning }) => {
  if (attachmentsWarning) {
    return <Warning message={<FormattedMessage id='compose_form.attachment_warning' defaultMessage='Attached media after the 5th may not be visible to remote followers. (Post public or unlisted so remote users can see it from the public link)' />} />;
  }

  return null;
};

AttachmentWarningWrapper.propTypes = {
  attachmentsWarning: PropTypes.bool,
};

const PrivacyWarningWrapper = ({ needsLockWarning, hashtagWarning, directMessageWarning, limitedMessageWarning, mutualMessageWarning, personalMessageWarning }) => {
  if (needsLockWarning) {
    return <Warning message={<FormattedMessage id='compose_form.lock_disclaimer' defaultMessage='Your account is not {locked}. Anyone can follow you to view your follower-only posts.' values={{ locked: <a href='/settings/profile'><FormattedMessage id='compose_form.lock_disclaimer.lock' defaultMessage='locked' /></a> }} />} />;
  }

  if (hashtagWarning) {
    return <Warning message={<FormattedMessage id='compose_form.hashtag_warning' defaultMessage="This toot won't be listed under any hashtag as it is unlisted. Only public toots can be searched by hashtag." />} />;
  }

  if (directMessageWarning) {
    const message = (
      <span>
        <FormattedMessage id='compose_form.direct_message_warning' defaultMessage='This toot will only be sent to all the mentioned users.' /> <a href='/terms' target='_blank'><FormattedMessage id='compose_form.direct_message_warning_learn_more' defaultMessage='Learn more' /></a>
      </span>
    );

    return <Warning message={message} />;
  }

  if (limitedMessageWarning) {
    return <Warning message={<FormattedMessage id='compose_form.limited_message_warning' defaultMessage='This toot will only be sent to users in the circle.' />} />;
  }

  if (mutualMessageWarning) {
    return <Warning message={<FormattedMessage id='compose_form.mutual_message_warning' defaultMessage='This toot will only be sent to users in the circle.' />} />;
  }

  if (personalMessageWarning) {
    return <Warning message={<FormattedMessage id='compose_form.personal_message_warning' defaultMessage='This toot will only be sent to users in the circle.' />} />;
  }

  return null;
};

PrivacyWarningWrapper.propTypes = {
  needsLockWarning: PropTypes.bool,
  hashtagWarning: PropTypes.bool,
  directMessageWarning: PropTypes.bool,
  limitedMessageWarning: PropTypes.bool,
  mutualMessageWarning: PropTypes.bool,
  personalMessageWarning: PropTypes.bool,
};

const WarningWrapper = (props) => {
  return (
    <Fragment>
      <ScheduledStatusWarningWrapper {...props} />
      <AttachmentWarningWrapper {...props} />
      <PrivacyWarningWrapper {...props} />
    </Fragment>
  );
};

WarningWrapper.propTypes = {
  needsLockWarning: PropTypes.bool,
  hashtagWarning: PropTypes.bool,
  directMessageWarning: PropTypes.bool,
  limitedMessageWarning: PropTypes.bool,
  mutualMessageWarning: PropTypes.bool,
  personalMessageWarning: PropTypes.bool,
  isScheduledStatusEditting: PropTypes.bool,
  isEditing: PropTypes.bool,
  onCancel: PropTypes.func.isRequired,
};

export default connect(mapStateToProps, mapDispatchToProps)(WarningWrapper);
