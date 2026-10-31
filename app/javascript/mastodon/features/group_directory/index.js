import React from 'react';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import Column from 'mastodon/components/column';
import ColumnHeader from 'mastodon/components/column_header';
import { addColumn, removeColumn, moveColumn, changeColumnParams } from 'mastodon/actions/columns';
import { fetchGroupDirectory, expandGroupDirectory, discardGroupDirectory } from 'mastodon/actions/group_directory';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import AccountCard from './components/account_card';
import GroupDirectoryFilterForm from './components/filter_form';
import classNames from 'classnames';
import LoadMore from 'mastodon/components/load_more';
import { ScrollContainer } from 'react-router-scroll-4';
import { defaultColumnWidth, me } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { groupDirectoryFilterKey, groupDirectoryViewKey } from './params';

const messages = defineMessages({
  title: { id: 'column.group_directory', defaultMessage: 'Browse groups' },
  empty: { id: 'group_directory.empty', defaultMessage: 'No groups match these filters' },
  error: { id: 'group_directory.error', defaultMessage: 'The group directory could not be loaded' },
  retry: { id: 'group_directory.retry', defaultMessage: 'Try again' },
  end: { id: 'group_directory.end', defaultMessage: 'End of the directory' },
});

const mapStateToProps = (state, ownProps) => {
  const viewKey = groupDirectoryViewKey(ownProps.columnId);
  const list = state.getIn(['user_lists', 'group_directories', viewKey]);

  return {
    viewKey,
    accountIds: list ? list.get('items', ImmutableList()) : ImmutableList(),
    directories: list ? list.get('directories', ImmutableMap()) : ImmutableMap(),
    isLoading: list ? list.get('isLoading') : true,
    isExpanding: list ? list.get('isExpanding') : false,
    exhausted: list ? list.get('exhausted') : false,
    hasError: list ? list.get('error') : false,
    failure: list ? list.get('failure') : null,
    columnWidth: state.getIn(['settings', 'group_directory', 'columnWidth'], defaultColumnWidth),
  };
};

export default @connect(mapStateToProps)
@injectIntl
class GroupDirectory extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    isLoading: PropTypes.bool,
    isExpanding: PropTypes.bool,
    exhausted: PropTypes.bool,
    hasError: PropTypes.bool,
    failure: PropTypes.oneOf(['fetch', 'expand', null]),
    accountIds: ImmutablePropTypes.list.isRequired,
    directories: ImmutablePropTypes.map.isRequired,
    viewKey: PropTypes.string.isRequired,
    dispatch: PropTypes.func.isRequired,
    columnId: PropTypes.string,
    intl: PropTypes.object.isRequired,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    params: PropTypes.shape({
      order: PropTypes.string,
      scope: PropTypes.string,
      software: PropTypes.string,
      q: PropTypes.string,
    }),
  };

  state = {
    order: null,
    scope: null,
    software: null,
    q: null,
  };

  handlePin = () => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(removeColumn(columnId));
    } else {
      dispatch(addColumn('GROUP_DIRECTORY', this.getParams(this.props, this.state)));
    }
  }

  getParams = (props, state) => ({
    order: state.order === null ? ((props.params && props.params.order) || 'active') : state.order,
    scope: state.scope === null ? ((props.params && props.params.scope) || 'all') : state.scope,
    software: state.software === null ? ((props.params && props.params.software) || '') : state.software,
    q: state.q === null ? ((props.params && props.params.q) || '') : state.q,
  });

  handleMove = dir => {
    const { columnId, dispatch } = this.props;
    dispatch(moveColumn(columnId, dir));
  }

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  componentDidMount () {
    const { dispatch, viewKey } = this.props;
    dispatch(fetchGroupDirectory(viewKey, this.getParams(this.props, this.state)));
  }

  componentDidUpdate (prevProps, prevState) {
    const { dispatch, viewKey } = this.props;
    const paramsOld = this.getParams(prevProps, prevState);
    const paramsNew = this.getParams(this.props, this.state);

    if (groupDirectoryFilterKey(paramsOld) !== groupDirectoryFilterKey(paramsNew)) {
      dispatch(fetchGroupDirectory(viewKey, paramsNew));
    }
  }

  componentWillUnmount () {
    this.props.dispatch(discardGroupDirectory(this.props.viewKey));
  }

  setRef = c => {
    this.column = c;
  }

  handleParamsChange = (patch) => {
    const { dispatch, columnId } = this.props;

    if (columnId) {
      Object.keys(patch).forEach(key => {
        dispatch(changeColumnParams(columnId, [key], patch[key]));
      });
      return;
    }

    this.setState(patch);
  }

  handleLoadMore = () => {
    const { dispatch, viewKey } = this.props;
    dispatch(expandGroupDirectory(viewKey, this.getParams(this.props, this.state)));
  }

  handleWidthChange = (value) => {
    this.props.dispatch(changeSetting(['group_directory', 'columnWidth'], value));
  }

  render () {
    const { isLoading, isExpanding, exhausted, hasError, accountIds, directories, intl, columnId, multiColumn, columnWidth, viewKey } = this.props;
    const params = this.getParams(this.props, this.state);
    const pinned = !!columnId;
    const showMore = !isLoading && !isExpanding && !exhausted && !hasError && accountIds.size > 0;

    const scrollableArea = (
      <div className='scrollable' style={{ background: 'transparent' }}>
        <GroupDirectoryFilterForm
          viewKey={viewKey}
          params={params}
          signedIn={!!me}
          onChange={this.handleParamsChange}
        />

        <ul className={classNames('directory__list', 'directory__list--groups', { loading: isLoading })}>
          {accountIds.map(accountId => (
            <li key={accountId}>
              <AccountCard id={accountId} directory={directories.get(accountId)} />
            </li>
          ))}
        </ul>

        <div className='group-directory-status' aria-live='polite'>
          {hasError && (
            <div role='alert'>
              <p>{intl.formatMessage(messages.error)}</p>
              <button type='button' className='group-directory-status__retry' onClick={this.handleRetry}>
                {intl.formatMessage(messages.retry)}
              </button>
            </div>
          )}
          {!isLoading && !hasError && accountIds.isEmpty() && (
            <p>{intl.formatMessage(messages.empty)}</p>
          )}
          {exhausted && !accountIds.isEmpty() && !hasError && (
            <p>{intl.formatMessage(messages.end)}</p>
          )}
        </div>

        <LoadMore onClick={this.handleLoadMore} visible={showMore} />
      </div>
    );

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)} columnWidth={columnWidth}>
        <ColumnHeader
          icon='address-book-o'
          title={intl.formatMessage(messages.title)}
          onPin={this.handlePin}
          onMove={this.handleMove}
          onClick={this.handleHeaderClick}
          pinned={pinned}
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        />

        {multiColumn && !pinned ? <ScrollContainer scrollKey={`group-directory-${viewKey}`}>{scrollableArea}</ScrollContainer> : scrollableArea}
      </Column>
    );
  }

  handleRetry = () => {
    const { dispatch, failure, viewKey } = this.props;
    const params = this.getParams(this.props, this.state);

    if (failure === 'expand') {
      dispatch(expandGroupDirectory(viewKey, params));
      return;
    }

    dispatch(fetchGroupDirectory(viewKey, params));
  }

}
