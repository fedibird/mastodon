import React from 'react';
import { connect } from 'react-redux';
import ImmutablePureComponent from 'react-immutable-pure-component';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import LoadingIndicator from '../../components/loading_indicator';
import { fetchReblogs, expandReblogs } from '../../actions/interactions';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import AccountContainer from '../../containers/account_container';
import ReblogWrapperLink from '../account_context/components/reblog_wrapper_link';
import Column from '../ui/components/column';
import ScrollableList from '../../components/scrollable_list';
import Icon from 'mastodon/components/icon';
import ColumnHeader from '../../components/column_header';
import ReactedHeaderContaier from '../reactioned/containers/header_container';
import { debounce } from 'lodash';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  refresh: { id: 'refresh', defaultMessage: 'Refresh' },
});

const mapStateToProps = (state, { columnId, params }) => {
  const uuid = columnId;
  const columns = state.getIn(['settings', 'columns']);
  const index = columns.findIndex(c => c.get('uuid') === uuid);
  const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'reblogs', 'columnWidth']);

  return {
    accountIds: state.getIn(['user_lists', 'reblogged_by', params.statusId, 'items']),
    isLoading: state.getIn(['user_lists', 'reblogged_by', params.statusId, 'isLoading'], true),
    hasMore: !!state.getIn(['user_lists', 'reblogged_by', params.statusId, 'next']),
    columnWidth: columnWidth ?? defaultColumnWidth,
  };
};

export default @connect(mapStateToProps)
@injectIntl
class Reblogs extends ImmutablePureComponent {

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    accountIds: ImmutablePropTypes.list,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    intl: PropTypes.object.isRequired,
    hasMore: PropTypes.bool,
    isLoading: PropTypes.bool,
  };

  componentWillMount () {
    if (!this.props.accountIds) {
      this.props.dispatch(fetchReblogs(this.props.params.statusId));
    }
  }

  componentWillReceiveProps(nextProps) {
    if (nextProps.params.statusId !== this.props.params.statusId && nextProps.params.statusId) {
      this.props.dispatch(fetchReblogs(nextProps.params.statusId));
    }
  }

  handleRefresh = () => {
    this.props.dispatch(fetchReblogs(this.props.params.statusId));
  }

  handleLoadMore = debounce(() => {
    this.props.dispatch(expandReblogs(this.props.params.statusId));
  }, 300, { leading: true })

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['reblogs', 'columnWidth'], value));
    }
  }

  render () {
    const { intl, accountIds, multiColumn, hasMore, isLoading, columnWidth, columnId } = this.props;

    if (!accountIds) {
      return (
        <Column>
          <LoadingIndicator />
        </Column>
      );
    }

    const emptyMessage = <FormattedMessage id='status.reblogs.empty' defaultMessage='No one has boosted this toot yet. When someone does, they will show up here.' />;

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
          scrollKey='reblogs'
          hasMore={hasMore}
          isLoading={isLoading}
          onLoadMore={this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
        >
          {accountIds.map(id => (
            <div key={id} className='account-context-reblog-row'>
              <AccountContainer id={id} withNote={false} />
              <ReblogWrapperLink
                accountId={id}
                originalStatusId={this.props.params.statusId}
                hostTimelineId={columnId ? `reblogs:${columnId}:${this.props.params.statusId}` : `reblogs:route:${this.props.params.statusId}`}
              />
            </div>
          ))}
        </ScrollableList>
      </Column>
    );
  }

}
