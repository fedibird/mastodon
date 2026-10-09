import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import { withRouter } from 'react-router-dom';
import { List as ImmutableList } from 'immutable';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import { defaultColumnWidth } from 'mastodon/initial_state';
import { isMixEnabled } from 'mastodon/mix/availability';
import { addDraftSource, emptyMixDraft, moveDraftSource, plainMix, removeDraftSource, retitleDraft } from 'mastodon/mix/definition';
import { createMix, deleteMix, searchMixSources, updateMix } from '../../actions/mixes';
import { fetchLists } from '../../actions/lists';
import messages from './messages';
import MixEditorForm from './components/editor_form';

const plainLists = (lists) => {
  if (!lists || !lists.toList) {
    return [];
  }

  return lists.toList().filter(item => item && item.get).map(item => ({
    id: item.get('id'),
    title: item.get('title'),
  })).toArray();
};

const mapStateToProps = (state, { params }) => ({
  mixId: params && params.id ? String(params.id) : null,
  mix: params && params.id ? state.getIn(['settings', 'mixes'], ImmutableList()).find(item => item && item.get('id') === String(params.id)) : null,
  lists: plainLists(state.get('lists')),
  enabled: isMixEnabled(),
  columnWidth: defaultColumnWidth,
});

export class MixEditorPage extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    history: PropTypes.shape({
      push: PropTypes.func.isRequired,
    }).isRequired,
    mixId: PropTypes.string,
    mix: PropTypes.object,
    lists: PropTypes.array,
    enabled: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  state = {
    draft: emptyMixDraft(),
    errors: [],
    confirmingDelete: false,
  };

  componentWillMount () {
    this.props.dispatch(fetchLists());
    this.resetDraft(this.props);
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.mixId !== this.props.mixId) {
      this.resetDraft(nextProps);
    }
  }

  resetDraft (props) {
    const plain = props.mix ? plainMix(props.mix) : emptyMixDraft();

    this.setState({
      draft: {
        title: plain.title || '',
        sources: plain.sources || [],
      },
      errors: [],
      confirmingDelete: false,
    });
  }

  handleTitleChange = (title) => {
    this.setState(state => ({
      draft: retitleDraft(state.draft, title),
      confirmingDelete: false,
    }));
  };

  handleAddSource = (raw) => {
    const result = addDraftSource(this.state.draft, raw);

    if (!result.ok) {
      this.setState({ errors: [result.error] });
      return false;
    }

    this.setState({ draft: result.draft, errors: [], confirmingDelete: false });
    return true;
  };

  handleRemoveSource = (index) => {
    this.setState(state => ({
      draft: removeDraftSource(state.draft, index),
      errors: [],
      confirmingDelete: false,
    }));
  };

  handleMoveSource = (index, direction) => {
    this.setState(state => ({
      draft: moveDraftSource(state.draft, index, direction),
      confirmingDelete: false,
    }));
  };

  handleSearch = (type, query) => this.props.dispatch(searchMixSources(type, query));

  handleSave = () => {
    const { dispatch, history, mixId } = this.props;
    const result = mixId ? dispatch(updateMix(mixId, this.state.draft)) : dispatch(createMix(this.state.draft));

    if (!result.ok) {
      this.setState({ errors: result.errors || [result.error].filter(Boolean) });
      return;
    }

    history.push(`/timelines/mixes/${result.mix.id}`);
  };

  handleCancel = () => {
    this.props.history.push('/mixes');
  };

  handleDelete = () => {
    if (!this.state.confirmingDelete) {
      this.setState({ confirmingDelete: true });
      return;
    }

    const result = this.props.dispatch(deleteMix(this.props.mixId));

    if (result.ok) {
      this.props.history.push('/mixes');
    } else {
      this.setState({ errors: result.errors || [] });
    }
  };

  handleHeaderClick = () => {
    if (this.column) {
      this.column.scrollTop();
    }
  };

  setRef = (c) => {
    this.column = c;
  };

  render () {
    const { intl, mixId, mix, lists, enabled, multiColumn, columnWidth } = this.props;
    const missing = !!mixId && !mix;
    const title = intl.formatMessage(mixId ? messages.edit : messages.create);

    let body;

    if (!enabled) {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.unavailable)}</p>;
    } else if (missing) {
      body = <p className='mix-editor__notice'>{intl.formatMessage(messages.deleted)}</p>;
    } else {
      body = (
        <div className='scrollable'>
          <MixEditorForm
            intl={intl}
            title={this.state.draft.title}
            sources={this.state.draft.sources}
            lists={lists}
            errors={this.state.errors}
            editing={!!mixId}
            confirmingDelete={this.state.confirmingDelete}
            onTitleChange={this.handleTitleChange}
            onAddSource={this.handleAddSource}
            onRemoveSource={this.handleRemoveSource}
            onMoveSource={this.handleMoveSource}
            onSave={this.handleSave}
            onCancel={this.handleCancel}
            onDelete={this.handleDelete}
            onSearch={this.handleSearch}
          />
        </div>
      );
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={title} columnWidth={columnWidth}>
        <ColumnHeader
          icon='random'
          title={title}
          onClick={this.handleHeaderClick}
          multiColumn={multiColumn}
          showBackButton
        />
        {body}
      </Column>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
@withRouter
class MixEditor extends MixEditorPage {}
