import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import StatusListContainer from '../ui/containers/status_list_container';
import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';
import ColumnSettingsContainer from './containers/column_settings_container';
import { expandHashtagTimeline, clearTimeline } from 'mastodon/actions/timelines';
import { addColumn, removeColumn, moveColumn } from 'mastodon/actions/columns';
import { injectIntl, FormattedMessage, defineMessages } from 'react-intl';
import { connectHashtagStream } from 'mastodon/actions/streaming';
import { isEqual } from 'lodash';
import { fetchHashtag, followHashtag, unfollowHashtag } from 'mastodon/actions/tags';
import Icon from 'mastodon/components/icon';
import classNames from 'classnames';
import { defaultColumnWidth, followTagModal, unfollowTagModal, new_features_policy } from 'mastodon/initial_state';
import PortableComposer from '../compose/portable_composer';
import { buildHashtagTimelinePostingContext } from 'mastodon/posting_context/hashtag';
import { normalizeManagedHashtagName } from 'mastodon/posting_context/managed_hashtags';
import { openModal } from 'mastodon/actions/modal';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  followHashtag: { id: 'hashtag.follow', defaultMessage: 'Follow hashtag' },
  unfollowHashtag: { id: 'hashtag.unfollow', defaultMessage: 'Unfollow hashtag' },
  followHashtagConfirm: { id: 'confirmations.follow_hashtag.confirm', defaultMessage: 'Follow hastag' },
  unfollowHashtagConfirm: { id: 'confirmations.unfollow_hashtag.confirm', defaultMessage: 'Unfollow hashtag' },
});

const mapStateToProps = (state, { columnId, params }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns.findIndex(c => c.get('uuid') === uuid);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'hashtag', 'columnWidth']);

  return {
    hasUnread: state.getIn(['timelines', `hashtag:${params.id}`, 'unread']) > 0,
    tag: state.getIn(['tags', params.id]),
    columnWidth: columnWidth ?? defaultColumnWidth,
  };
};

class HashtagTimeline extends React.PureComponent {

  disconnects = [];

  static propTypes = {
    params: PropTypes.object.isRequired,
    columnId: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    hasUnread: PropTypes.bool,
    tag: ImmutablePropTypes.map,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    intl: PropTypes.object,
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('HASHTAG', { id: this.props.params.id }));
    }
  }

  title = () => {
    const { id } = this.props.params;
    const title  = [id];

    if (this.additionalFor('any')) {
      title.push(' ', <FormattedMessage key='any' id='hashtag.column_header.tag_mode.any'  values={{ additional: this.additionalFor('any') }} defaultMessage='or {additional}' />);
    }

    if (this.additionalFor('all')) {
      title.push(' ', <FormattedMessage key='all' id='hashtag.column_header.tag_mode.all'  values={{ additional: this.additionalFor('all') }} defaultMessage='and {additional}' />);
    }

    if (this.additionalFor('none')) {
      title.push(' ', <FormattedMessage key='none' id='hashtag.column_header.tag_mode.none' values={{ additional: this.additionalFor('none') }} defaultMessage='without {additional}' />);
    }

    return title;
  }

  additionalFor = (mode) => {
    const { tags } = this.props.params;

    if (tags && (tags[mode] || []).length > 0) {
      return tags[mode].map(tag => tag.value).join('/');
    } else {
      return '';
    }
  }

  handleMove = (dir) => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  _subscribe (dispatch, id, tags = {}) {
    let any  = (tags.any || []).map(tag => tag.value);
    let all  = (tags.all || []).map(tag => tag.value);
    let none = (tags.none || []).map(tag => tag.value);

    [id, ...any].map(tag => {
      this.disconnects.push(dispatch(connectHashtagStream(id, tag, status => {
        let tags = status.tags.map(tag => tag.name);

        return all.filter(tag => tags.includes(tag)).length === all.length &&
               none.filter(tag => tags.includes(tag)).length === 0;
      })));
    });
  }

  _unsubscribe () {
    this.disconnects.map(disconnect => disconnect());
    this.disconnects = [];
  }

  _unload () {
    const { dispatch } = this.props;
    const { id } = this.props.params;

    this._unsubscribe();
    dispatch(clearTimeline(`hashtag:${id}`));
  }

  _load() {
    const { dispatch } = this.props;
    const { id, tags } = this.props.params;

    this._subscribe(dispatch, id, tags);
    dispatch(expandHashtagTimeline(id, { tags }));
    dispatch(fetchHashtag(id));
  }

  componentDidMount () {
    this._load();
  }

  componentDidUpdate (prevProps) {
    const { params } = this.props;
    const { id, tags } = prevProps.params;

    if (id !== params.id || !isEqual(tags, params.tags)) {
      this._unload();
      this._load();
    }
  }

  componentWillUnmount () {
    this._unsubscribe();
  }

  setRef = c => {
    this.column = c;
  }

  handleLoadMore = maxId => {
    const { dispatch, params } = this.props;
    const { id, tags }  = params;

    dispatch(expandHashtagTimeline(id, { maxId, tags }));
  }

  handleFollow = () => {
    const { intl, dispatch, params, tag } = this.props;
    const { id } = params;

    if (tag.get('following')) {
      if (unfollowTagModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unfollow_hashtag.message' defaultMessage='Are you sure you want to unfollow hashtag {name}?' values={{ name: <strong> #{tag.get('name')}</strong> }} />,
          confirm: intl.formatMessage(messages.unfollowHashtagConfirm),
          onConfirm: () => dispatch(unfollowHashtag(id)),
        }));
      } else {
        dispatch(unfollowHashtag(id));
      }
    } else {
      if (followTagModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.follow_hashtag.message' defaultMessage='Are you sure you want to follow hashtag {name}?' values={{ name: <strong>#{tag.get('name')}</strong> }} />,
          confirm: intl.formatMessage(messages.followHashtagConfirm),
          onConfirm: () => dispatch(followHashtag(id)),
        }));
      } else {
        dispatch(followHashtag(id));
      }
    }
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['hashtag', 'columnWidth'], value));
    }
  }

  render () {
    const { hasUnread, columnId, multiColumn, tag, columnWidth, intl } = this.props;
    const { id } = this.props.params;
    const pinned = !!columnId;
    const normalizedTag = normalizeManagedHashtagName(id);
    const composerId = columnId ? `portable:hashtag-column:${columnId}` : `portable:hashtag-route:${normalizedTag}`;
    const portableComposer = new_features_policy === 'tester' ? (
      <PortableComposer
        key={composerId}
        composerId={composerId}
        postingContext={buildHashtagTimelinePostingContext(id)}
      />
    ) : null;

    let followButton;

    if (tag) {
      const following = tag.get('following');

      followButton = (
        <button className={classNames('column-header__button', 'column-header__follow_button', { active: following })} onClick={this.handleFollow} title={intl.formatMessage(following ? messages.unfollowHashtag : messages.followHashtag)} aria-label={intl.formatMessage(following ? messages.unfollowHashtag : messages.followHashtag)} aria-pressed={following ? 'true' : 'false'}>
          <Icon id={following ? 'user-times' : 'user-plus'} fixedWidth className='column-header__icon' />
        </button>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={`#${id}`} columnWidth={columnWidth}>
        <ColumnHeader
          icon='hashtag'
          active={hasUnread}
          title={this.title()}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          extraButton={followButton}
          showBackButton
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          {columnId && <ColumnSettingsContainer columnId={columnId} />}
        </ColumnHeader>

        <StatusListContainer
          trackScroll={!pinned}
          scrollKey={`hashtag_timeline-${columnId}`}
          timelineId={`hashtag:${id}`}
          onLoadMore={this.handleLoadMore}
          emptyMessage={<FormattedMessage id='empty_column.hashtag' defaultMessage='There is nothing in this hashtag yet.' />}
          bindToDocument={!multiColumn}
          prepend={portableComposer}
          alwaysPrepend={!!portableComposer}
        />
      </Column>
    );
  }

}

export default injectIntl(connect(mapStateToProps)(HashtagTimeline));
