import React from 'react';
import { connect } from 'react-redux';
import ImmutablePureComponent from 'react-immutable-pure-component';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import LoadingIndicator from '../../components/loading_indicator';
import { fetchEmojiReactions, expandEmojiReactions } from '../../actions/interactions';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import AccountContainer from '../../containers/account_container';
import Column from '../ui/components/column';
import ScrollableList from '../../components/scrollable_list';
import Icon from 'mastodon/components/icon';
import ColumnHeader from '../../components/column_header';
import Emoji from '../../components/emoji';
import { attachInlineEmojiMenus, handleInlineEmojiClick } from 'mastodon/features/emoji/emoji_actions/inline_emoji';
import ReactedHeaderContaier from '../reactioned/containers/header_container';
import { debounce } from 'lodash';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';
import { storedReactionHidden } from 'mastodon/features/emoji/emoji_mute_projection';
import { UNVERIFIED_EMOJI_PLACEHOLDER } from 'mastodon/features/emoji/emoji_mute_text';

const messages = defineMessages({
  refresh: { id: 'refresh', defaultMessage: 'Refresh' },
});

const mapStateToProps = (state, { columnId, params: { statusId } }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns.findIndex(c => c.get('uuid') === uuid);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'emoji_reactioned_by', 'columnWidth']);

  return {
    emojiReactions: state.getIn(['user_lists', 'emoji_reactioned_by', statusId, 'items']),
    isLoading: state.getIn(['user_lists', 'emoji_reactioned_by', statusId, 'isLoading'], true),
    hasMore: !!state.getIn(['user_lists', 'emoji_reactioned_by', statusId, 'next']),
    columnWidth: columnWidth ?? defaultColumnWidth,
  };
};

const mapReactionStateToProps = (state, { emojiReaction }) => {
  const display = state.getIn(['emojiMutes', 'display']);

  return {
    suppressed: display === 'suppress',
    hiddenByRule: display !== 'show' && display !== 'suppress' && storedReactionHidden(emojiReaction, state.getIn(['emojiMutes', 'rules'])),
  };
};

class Reaction extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    emojiReaction: ImmutablePropTypes.map.isRequired,
    suppressed: PropTypes.bool,
    hiddenByRule: PropTypes.bool,
  };

  state = {
    hovered: false,
  };

  handleEmojiClick = e => {
    handleInlineEmojiClick(e, e.currentTarget, this.context.router, { source: 'emoji_reaction_overview' });
  }

  componentDidMount () {
    this.updateEmojiMenu();
  }

  componentDidUpdate () {
    this.updateEmojiMenu();
  }

  componentWillUnmount () {
    this.detachInlineEmojiMenus?.();
  }

  setRef = node => {
    this.node = node;
  };

  updateEmojiMenu = () => {
    this.detachInlineEmojiMenus?.();
    this.detachInlineEmojiMenus = attachInlineEmojiMenus(this.node, { source: 'emoji_reaction_overview' });
  };

  handleMouseEnter = () => this.setState({ hovered: true })

  handleMouseLeave = () => this.setState({ hovered: false })

  render () {
    const { emojiReaction, suppressed, hiddenByRule } = this.props;
    const title = emojiReaction.get('alternate_name') ?? emojiReaction.get('name');
    let glyph = null;

    if (suppressed) {
      glyph = <span className='emoji-mute-unverified' aria-hidden='true'>{UNVERIFIED_EMOJI_PLACEHOLDER}</span>;
    } else if (!hiddenByRule) {
      glyph = <Emoji className='reaction' hovered={this.state.hovered} emoji={emojiReaction.get('name')} url={emojiReaction.get('url')} static_url={emojiReaction.get('static_url')} domain={emojiReaction.get('domain')} title={title} onClick={this.handleEmojiClick} />;
    }

    const name = emojiReaction.get('name') || '';
    const domain = emojiReaction.get('domain') || '';
    const customEmojiId = emojiReaction.get('custom_emoji_id') || '';
    const identity = {
      'data-emoji-reaction-name': name,
    };

    if (domain) {
      identity['data-emoji-reaction-domain'] = domain;
    }

    if (customEmojiId) {
      identity['data-emoji-custom-emoji-id'] = String(customEmojiId);
    }

    if (!domain && !customEmojiId && name) {
      identity['data-emoji-native'] = name;
    }

    return (
      <div className='account__emoji_reaction' {...identity} onMouseEnter={this.handleMouseEnter} onMouseLeave={this.handleMouseLeave} ref={this.setRef}>
        {glyph}
      </div>
    );
  };

}

const ConnectedReaction = connect(mapReactionStateToProps)(Reaction);

class EmojiReactions extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    emojiReactions: ImmutablePropTypes.list,
    multiColumn: PropTypes.bool,
    columnId: PropTypes.string,
    columnWidth: PropTypes.string,
    intl: PropTypes.object.isRequired,
    hasMore: PropTypes.bool,
    isLoading: PropTypes.bool,
    params: PropTypes.shape({
      statusId: PropTypes.string,
    }),
  };

  componentDidMount () {
    const { emojiReactions, params: { statusId }, dispatch } = this.props;

    if (!emojiReactions) {
      dispatch(fetchEmojiReactions(statusId));
    }
  }

  componentDidUpdate (prevProps) {
    const { emojiReactions, params: { statusId }, dispatch } = this.props;

    if (!emojiReactions || prevProps.params.statusId !== statusId) {
      dispatch(fetchEmojiReactions(statusId));
    }
  }

  handleRefresh = () => {
    const { params: { statusId }, dispatch } = this.props;

    dispatch(fetchEmojiReactions(statusId));
  }

  handleLoadMore = debounce(() => {
    const { params: { statusId }, dispatch } = this.props;

    dispatch(expandEmojiReactions(statusId));
  }, 300, { leading: true })

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['emoji_reactions', 'columnWidth'], value));
    }
  }

  render () {
    const { intl, emojiReactions, multiColumn, hasMore, isLoading, columnWidth } = this.props;

    if (!emojiReactions) {
      return (
        <Column>
          <LoadingIndicator />
        </Column>
      );
    }

    const emptyMessage = <FormattedMessage id='empty_column.emoji_reactions' defaultMessage='No one has reactioned this post yet. When someone does, they will show up here.' />;

    return (
      <Column bindToDocument={!multiColumn} columnWidth={columnWidth}>
        <ColumnHeader
          showBackButton
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
          extraButton={(
            <button className='column-header__button' title={intl.formatMessage(messages.refresh)} aria-label={intl.formatMessage(messages.refresh)} onClick={this.handleRefresh}><Icon id='refresh' /></button>
          )}
        />

        <ReactedHeaderContaier statusId={this.props.params.statusId} />

        <ScrollableList
          scrollKey='emoji_reactions'
          hasMore={hasMore}
          isLoading={isLoading}
          onLoadMore={this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
        >
          {emojiReactions.map(emojiReaction =>
            <AccountContainer key={emojiReaction.get('account')+emojiReaction.get('name')} id={emojiReaction.get('account')} withNote={false} append={<ConnectedReaction emojiReaction={emojiReaction} />} />,
          )}
        </ScrollableList>
      </Column>
    );
  }

}

export default injectIntl(connect(mapStateToProps)(EmojiReactions));
