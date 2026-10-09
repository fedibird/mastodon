import React from 'react';
import PropTypes from 'prop-types';
import messages from '../messages';
import SourceForm from './source_form';
import SourceList from './source_list';

const errorMessage = (error) => ({
  title_blank: messages.titleBlank,
  title_too_long: messages.titleTooLong,
  sources_too_few: messages.sourcesTooFew,
  sources_too_many: messages.sourcesTooMany,
  source_duplicate: messages.sourceDuplicate,
  unavailable: messages.unavailable,
}[error] || messages.sourceInvalid);

export default class MixEditorForm extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    title: PropTypes.string.isRequired,
    sources: PropTypes.array.isRequired,
    lists: PropTypes.array,
    errors: PropTypes.arrayOf(PropTypes.string),
    editing: PropTypes.bool,
    onTitleChange: PropTypes.func.isRequired,
    onAddSource: PropTypes.func.isRequired,
    onRemoveSource: PropTypes.func.isRequired,
    onMoveSource: PropTypes.func.isRequired,
    onSave: PropTypes.func.isRequired,
    onCancel: PropTypes.func.isRequired,
    onDelete: PropTypes.func,
    onSearch: PropTypes.func.isRequired,
    confirmingDelete: PropTypes.bool,
  };

  static defaultProps = {
    lists: [],
    errors: [],
    editing: false,
    confirmingDelete: false,
  };

  handleTitle = (e) => {
    this.props.onTitleChange(e.target.value);
  };

  handleSubmit = (e) => {
    e.preventDefault();
    this.props.onSave();
  };

  render () {
    const {
      intl,
      title,
      sources,
      lists,
      errors,
      editing,
      onAddSource,
      onRemoveSource,
      onMoveSource,
      onCancel,
      onDelete,
      onSearch,
      confirmingDelete,
    } = this.props;

    return (
      <form className='mix-editor' onSubmit={this.handleSubmit}>
        <label className='mix-editor__label' htmlFor='mix-name'>{intl.formatMessage(messages.name)}</label>
        <input id='mix-name' className='setting-text' value={title} onChange={this.handleTitle} maxLength={100} />

        <h2 className='mix-editor__label'>{intl.formatMessage(messages.sources)}</h2>
        <SourceList sources={sources} intl={intl} editable onRemove={onRemoveSource} onMove={onMoveSource} />
        <SourceForm intl={intl} lists={lists} onAddSource={onAddSource} onSearch={onSearch} />

        {errors.length > 0 && (
          <div role='alert'>
            {Array.from(new Set(errors)).map(error => (
              <p key={error} className='mix-editor__error'>{intl.formatMessage(errorMessage(error))}</p>
            ))}
          </div>
        )}

        <div className='mix-editor__actions'>
          <button type='submit' className='button'>{intl.formatMessage(messages.save)}</button>
          <button type='button' className='button button-secondary' onClick={onCancel}>{intl.formatMessage(messages.cancel)}</button>
          {editing && onDelete && (
            <button type='button' className='button button-secondary' onClick={onDelete}>
              {intl.formatMessage(confirmingDelete ? messages.deleteConfirm : messages.delete)}
            </button>
          )}
        </div>
      </form>
    );
  }

}
