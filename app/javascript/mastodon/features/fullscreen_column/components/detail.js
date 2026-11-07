import React from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import Status from 'mastodon/features/status';
import AccountTimeline from 'mastodon/features/account_timeline';
import HashtagTimeline from 'mastodon/features/hashtag_timeline';
import ListTimeline from 'mastodon/features/list_timeline';

const matchPath = (path, expression) => {
  const match = String(path || '').split('?')[0].match(expression);
  return match ? decodeURIComponent(match[1]) : null;
};

export default class FullscreenDetail extends React.PureComponent {

  static propTypes = {
    path: PropTypes.string.isRequired,
  };

  render () {
    const path = this.props.path;
    const statusId = matchPath(path, /^\/statuses\/([^/]+)$/);
    const accountId = matchPath(path, /^\/accounts\/([^/]+)/);
    const tagId = matchPath(path, /^\/timelines\/tag\/([^/]+)/);
    const listId = matchPath(path, /^\/timelines\/list\/([^/]+)/);
    const withReplies = /^\/accounts\/[^/]+\/with_replies(?:\/|$)/.test(path);
    const posts = /^\/accounts\/[^/]+\/posts(?:\/|$)/.test(path);
    const about = /^\/accounts\/[^/]+\/about(?:\/|$)/.test(path);

    if (statusId) {
      return <Status params={{ statusId }} multiColumn fullscreenComposer />;
    }

    if (accountId && !/\/media(?:\/|$)/.test(path)) {
      return (
        <AccountTimeline
          params={{ accountId, tagged: matchPath(path, /^\/accounts\/[^/]+\/(?:about|posts|with_replies)\/([^/]+)/) }}
          withReplies={withReplies}
          posts={posts}
          about={about}
          multiColumn
        />
      );
    }

    if (tagId) {
      return <HashtagTimeline params={{ id: tagId }} multiColumn />;
    }

    if (listId) {
      return <ListTimeline params={{ id: listId }} multiColumn />;
    }

    return (
      <div className='fullscreen-column__unsupported'>
        <FormattedMessage id='fullscreen_column.detail_unavailable' defaultMessage='This page stays in the fullscreen column, but it has no contained view yet.' />
      </div>
    );
  }

}
