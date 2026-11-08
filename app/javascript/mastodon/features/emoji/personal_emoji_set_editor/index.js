import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import { v4 as uuid } from 'uuid';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import initialState from 'mastodon/initial_state_data';
import StockEmojiPicker from '../stock_emoji_picker';
import { firstGrapheme } from '../emoji_stock';
import { notifySavedPersonalEmojiSet } from '../emoji_stock_source';
import { loadPersonalEmojiSet, savePersonalEmojiSet, resolvePersonalEmoji } from './api';
import { categoryHeading, draftSnapshot, draftStock, itemCount, itemIdentity, itemLabel, MAX_CATEGORIES, MAX_CATEGORY_ITEMS, MAX_ITEMS, moveEntry, removeItem, representativeItem } from './draft';
import EmojiArt from './art';
import LazyStandardPicker, { loadEditorStandardPicker } from './lazy_standard_picker';
import messages from './messages';

const focusableSelector = 'button:not(:disabled), input:not(:disabled), select:not(:disabled), a[href], [tabindex="0"]';
const clone = value => JSON.parse(JSON.stringify(value));
const isComposition = event => event.isComposing || event.keyCode === 229 || event.nativeEvent?.isComposing;
const autoPlayEmoji = initialState?.meta?.auto_play_emoji;
const initialSkinTone = [1, 2, 3, 4, 5, 6].includes(initialState?.settings?.skinTone) ? initialState.settings.skinTone : 1;

function EditorButton({ action, id, icon, label, onAction, iconOnly, primary, danger, disabled, className }) {
  return (
    <button
      type='button'
      data-action={action}
      data-id={id}
      onClick={onAction}
      className={classNames(iconOnly ? 'pes-icon-button' : 'pes-button', className, { 'pes-primary': primary, 'pes-danger': danger })}
      disabled={disabled}
      title={label}
      aria-label={iconOnly ? label : undefined}
    >
      {icon && <Icon id={icon} aria-hidden='true' />}
      {!iconOnly && label}
    </button>
  );
}

EditorButton.propTypes = {
  action: PropTypes.string.isRequired,
  id: PropTypes.string,
  icon: PropTypes.string,
  label: PropTypes.string.isRequired,
  onAction: PropTypes.func.isRequired,
  iconOnly: PropTypes.bool,
  primary: PropTypes.bool,
  danger: PropTypes.bool,
  disabled: PropTypes.bool,
  className: PropTypes.string,
};

export class PersonalEmojiSetEditor extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    loadDocument: PropTypes.func,
    saveDocument: PropTypes.func,
    resolveEmoji: PropTypes.func,
    loadStandardPicker: PropTypes.func,
    onSaved: PropTypes.func,
  };

  static defaultProps = {
    loadDocument: loadPersonalEmojiSet,
    saveDocument: savePersonalEmojiSet,
    resolveEmoji: resolvePersonalEmoji,
    loadStandardPicker: loadEditorStandardPicker,
    onSaved: notifySavedPersonalEmojiSet,
  };

  state = {
    status: 'loading',
    revision: 0,
    categories: [],
    resolvedItems: {},
    pickerSize: 22,
    saved: null,
    saving: false,
    error: null,
    selectedCategoryId: null,
    selectedItemId: null,
    previewMode: 'personal',
    previewQuery: '',
    previewSelection: null,
    previewSkinTone: initialSkinTone,
    addSkinTone: initialSkinTone,
    dialog: null,
    candidates: [],
    resolving: 0,
    candidateError: null,
    candidateMessage: null,
    dropTarget: null,
  };

  componentDidMount() {
    this.mounted = true;
    this.generation = 0;
    this.dialogGeneration = 0;
    this.pendingCandidates = new Set();
    window.addEventListener('beforeunload', this.handleBeforeUnload);
    document.addEventListener('focusin', this.handleFocusIn);
    this.load();
  }

  componentWillUnmount() {
    this.mounted = false;
    this.generation += 1;
    this.dialogGeneration += 1;
    window.removeEventListener('beforeunload', this.handleBeforeUnload);
    document.removeEventListener('focusin', this.handleFocusIn);
    this.releaseModal();
  }

  setRootRef = node => {
    this.root = node;
  };
  setProductRef = node => {
    this.product = node;
  };
  setDialogRef = node => {
    this.dialogNode = node;
  };
  setNameRef = node => {
    this.nameInput = node;
  };
  setAppearanceRef = node => {
    this.appearance = node;
  };

  text = (key, values) => this.props.intl.formatMessage(messages[key], values);

  dirty() {
    return this.state.saved !== null && this.state.saved !== draftSnapshot(this.state.categories, this.state.pickerSize);
  }

  currentCategory() {
    return this.state.categories.find(category => category.id === this.state.selectedCategoryId);
  }

  currentItem() {
    return this.currentCategory()?.items.find(item => item.id === this.state.selectedItemId);
  }

  handleBeforeUnload = event => {
    if (this.dirty()) {
      event.preventDefault();
      event.returnValue = '';
    }
  };

  handleFocusIn = event => {
    if (this.state.dialog && this.dialogNode && !this.dialogNode.contains(event.target)) {
      this.dialogNode.querySelector(focusableSelector)?.focus();
    }
  };

  load = () => {
    const generation = ++this.generation;
    this.setState({ status: 'loading', error: null });
    Promise.resolve().then(() => this.props.loadDocument()).then(document => {
      if (this.mounted && generation === this.generation) {
        this.acceptDocument(document);
      }
    }).catch(() => {
      if (this.mounted && generation === this.generation) {
        this.setState({ status: 'error' });
      }
    });
  };

  acceptDocument(document) {
    this.savedDocument = clone(document);
    this.setState(previous => ({
      status: 'ready',
      saving: false,
      revision: document.revision,
      categories: document.categories,
      resolvedItems: document.resolved_items,
      pickerSize: document.picker_emoji_size,
      saved: draftSnapshot(document.categories, document.picker_emoji_size),
      selectedCategoryId: document.categories.some(category => category.id === previous.selectedCategoryId) ? previous.selectedCategoryId : document.categories[0]?.id || null,
      selectedItemId: null,
      error: null,
    }));
  }

  save = () => {
    if (this.state.saving || !this.dirty()) {
      return;
    }

    const invalid = this.state.categories.find(category => !category.name.trim());

    if (invalid) {
      this.setState({ error: 'categoryNameRequired', selectedCategoryId: invalid.id }, () => this.nameInput?.focus());
      return;
    }

    const request = {
      expected_revision: this.state.revision,
      expected_picker_emoji_size: this.savedDocument.picker_emoji_size,
      picker_emoji_size: this.state.pickerSize,
      categories: this.state.categories,
    };

    this.setState({ saving: true, error: null });
    Promise.resolve().then(() => this.props.saveDocument(request)).then(document => {
      this.props.onSaved(document);

      if (this.mounted) {
        this.acceptDocument(document);
      }
    }).catch(error => {
      if (this.mounted) {
        let kind = 'saveError';
        const patch = { saving: false };

        if (error.status === 409) {
          kind = 'conflict';
        } else if (error.status === 422) {
          kind = 'validationError';
          const failure = error.errors?.[0];
          const location = failure?.path?.match(/^categories\.(\d+)(?:\.items\.(\d+))?/);

          if (failure?.code === 'invalid_name') {
            kind = 'categoryNameInvalid';
          } else if (failure?.code === 'too_many_items') {
            kind = 'limit';
          }

          if (location) {
            const category = this.state.categories[Number(location[1])];
            patch.selectedCategoryId = category?.id || this.state.selectedCategoryId;
            patch.selectedItemId = category?.items[Number(location[2])]?.id || null;
          }
        }

        this.setState({ ...patch, error: kind }, () => {
          if (kind === 'categoryNameInvalid') {
            this.nameInput?.focus();
          } else if (patch.selectedItemId) {
            this.focusItem();
          }
        });
      }
    });
  };

  changeCategory(category, callback) {
    this.setState(previous => ({ categories: previous.categories.map(entry => entry.id === category.id ? category : entry), error: null }), callback);
  }

  handleName = event => this.changeCategory({ ...this.currentCategory(), name: event.target.value });

  handleHeading = event => {
    const value = event.target.value;
    let heading = { mode: 'emoji', item_id: value };

    if (value === '@first' || value === '@initial') {
      heading = { mode: value.slice(1) };
    }

    this.changeCategory({ ...this.currentCategory(), heading });
  };

  handleSize = event => this.setState({ pickerSize: Number(event.target.value), error: null });
  handlePreviewQuery = previewQuery => this.setState({ previewQuery });
  handlePreviewPick = emoji => this.setState({ previewSelection: emoji });
  handlePreviewSkinTone = previewSkinTone => this.setState({ previewSkinTone });
  handleAddSkinTone = addSkinTone => this.setState({ addSkinTone });

  focusCategory = () => {
    const button = Array.from(this.root.querySelectorAll('[data-action="category-select"]')).find(node => node.dataset.id === this.state.selectedCategoryId);
    (button || this.root.querySelector('[data-action="category-add"]'))?.focus({ preventScroll: true });
  };

  focusItem = () => {
    const button = Array.from(this.root.querySelectorAll('[data-action="item-select"]')).find(node => node.dataset.id === this.state.selectedItemId);
    (button || this.root.querySelector('[data-action="emoji-add"]'))?.focus({ preventScroll: true });
  };

  openDialog(kind) {
    this.returnFocus = document.activeElement;
    this.dialogGeneration += 1;
    this.pendingCandidates.clear();
    this.candidateOrder = 0;
    this.previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    this.setState({ dialog: kind, candidates: [], resolving: 0, candidateError: null, candidateMessage: null }, () => {
      if (this.product) {
        this.product.inert = true;
      }

      this.dialogNode?.querySelector(focusableSelector)?.focus({ preventScroll: true });
    });
  }

  releaseModal() {
    if (this.previousOverflow !== undefined) {
      document.body.style.overflow = this.previousOverflow;
      this.previousOverflow = undefined;
    }

    if (this.product) {
      this.product.inert = false;
    }
  }

  closeDialog(patch = {}, callback) {
    this.dialogGeneration += 1;
    this.pendingCandidates.clear();
    this.setState({ dialog: null, candidates: [], resolving: 0, ...patch }, () => {
      this.releaseModal();

      if (this.returnFocus?.isConnected && !this.returnFocus.disabled) {
        this.returnFocus.focus({ preventScroll: true });
      } else {
        this.focusCategory();
      }

      if (callback) {
        callback();
      }
    });
  }

  handleDialogKeyDown = event => {
    if (isComposition(event)) {
      return;
    }

    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      this.closeDialog();
    } else if (event.key === 'Tab') {
      const nodes = Array.from(this.dialogNode.querySelectorAll(focusableSelector)).filter(node => node.tabIndex >= 0 && !node.closest('[hidden]'));
      const first = nodes[0];
      const last = nodes[nodes.length - 1];

      if (event.shiftKey && (document.activeElement === first || !this.dialogNode.contains(document.activeElement))) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    }
  };

  handleCandidatePick = emoji => {
    const request = emoji.custom ? { kind: 'custom', shortcode: emoji.id } : { kind: 'unicode', native: emoji.native };
    const identity = emoji.custom ? `custom:${emoji.id}` : `unicode:${emoji.native}`;
    const category = this.currentCategory();
    const isSameSelection = item => !emoji.custom && item.kind === 'unicode' && item.native === emoji.native;

    if (category.items.some(isSameSelection)) {
      this.setState({ candidateMessage: 'alreadyAdded', candidateError: null });
      return;
    }

    const staged = this.state.candidates.find(candidate => isSameSelection(candidate.item));

    if (staged) {
      this.setState(previous => ({ candidates: previous.candidates.filter(candidate => candidate !== staged), candidateMessage: null }));
      return;
    }

    if (this.pendingCandidates.has(identity)) {
      return;
    }

    const pending = this.state.candidates.length + this.pendingCandidates.size;

    if (!emoji.custom && (category.items.length + pending >= MAX_CATEGORY_ITEMS || itemCount(this.state.categories) + pending >= MAX_ITEMS)) {
      this.setState({ candidateError: 'limit' });
      return;
    }

    const generation = this.dialogGeneration;
    const order = ++this.candidateOrder;
    this.pendingCandidates.add(identity);
    this.setState({ resolving: this.pendingCandidates.size, candidateError: null, candidateMessage: null });
    Promise.resolve().then(() => this.props.resolveEmoji(request)).then(resolved => {
      if (this.mounted && generation === this.dialogGeneration && this.state.dialog === 'add') {
        this.pendingCandidates.delete(identity);
        this.setState(previous => {
          const target = previous.categories.find(entry => entry.id === previous.selectedCategoryId);
          const resolvedIdentity = itemIdentity(resolved.item);
          const candidates = previous.candidates;
          const patch = { resolving: this.pendingCandidates.size };

          // Custom shortcodes may be reused after deletion. Resolve them to a
          // database identity before comparing either saved or staged entries.
          if (target.items.some(entry => itemIdentity(entry) === resolvedIdentity)) {
            return { ...patch, candidateMessage: 'alreadyAdded' };
          }

          if (candidates.some(candidate => itemIdentity(candidate.item) === resolvedIdentity)) {
            return { ...patch, candidates: candidates.filter(candidate => itemIdentity(candidate.item) !== resolvedIdentity) };
          }

          if (target.items.length + candidates.length >= MAX_CATEGORY_ITEMS || itemCount(previous.categories) + candidates.length >= MAX_ITEMS) {
            return { ...patch, candidateError: 'limit' };
          }

          return { ...patch, candidates: [...candidates, { item: { ...resolved.item, id: uuid() }, resolved: resolved.resolved, order }].sort((left, right) => left.order - right.order) };
        });
      }
    }).catch(() => {
      if (this.mounted && generation === this.dialogGeneration && this.state.dialog === 'add') {
        this.pendingCandidates.delete(identity);
        this.setState({ resolving: this.pendingCandidates.size, candidateError: 'resolveError' });
      }
    });
  };

  handleDragStart = event => {
    if (this.state.saving) {
      event.preventDefault();
      return;
    }

    this.drag = { kind: event.currentTarget.dataset.dragKind, id: event.currentTarget.dataset.id };
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', this.drag.id);
  };

  handleDragOver = event => {
    if (this.drag && this.drag.kind === event.currentTarget.dataset.dragKind) {
      event.preventDefault();
      event.dataTransfer.dropEffect = 'move';
      this.setState({ dropTarget: `${this.drag.kind}:${event.currentTarget.dataset.id}` });
    }
  };

  handleDragEnd = () => {
    this.drag = null;
    this.setState({ dropTarget: null });
  };

  handleDrop = event => {
    if (!this.drag || this.drag.kind !== event.currentTarget.dataset.dragKind || this.state.saving) {
      return;
    }

    event.preventDefault();
    const { kind, id } = this.drag;
    const target = event.currentTarget.dataset.id;

    if (kind === 'category') {
      this.setState(previous => ({ categories: moveEntry(previous.categories, id, previous.categories.findIndex(category => category.id === target)), selectedCategoryId: id }), this.focusCategory);
    } else {
      const category = this.currentCategory();
      this.setState({ selectedItemId: id });
      this.changeCategory({ ...category, items: moveEntry(category.items, id, category.items.findIndex(item => item.id === target)) }, this.focusItem);
    }

    this.handleDragEnd();
  };

  handleAction = event => {
    const { action, id } = event.currentTarget.dataset;
    const category = this.currentCategory();
    const item = this.currentItem();
    const categoryIndex = this.state.categories.indexOf(category);

    switch (action) {
    case 'save':
      this.save();
      break;
    case 'category-select':
      this.setState({ selectedCategoryId: id, selectedItemId: null, previewQuery: '' });
      break;
    case 'category-add': {
      if (this.state.categories.length >= MAX_CATEGORIES) {
        this.setState({ error: 'limit' });
        break;
      }

      const added = { id: uuid(), name: this.text('categoryNew'), heading: { mode: 'first' }, items: [] };
      this.setState(previous => ({ categories: [...previous.categories, added], selectedCategoryId: added.id, selectedItemId: null, previewQuery: '', error: null }), () => {
        this.nameInput?.focus({ preventScroll: true });
        this.nameInput?.select();
      });
      break;
    }
    case 'category-up':
    case 'category-down':
      this.setState(previous => ({ categories: moveEntry(previous.categories, category.id, categoryIndex + (action === 'category-up' ? -1 : 1)) }), this.focusCategory);
      break;
    case 'category-delete':
      this.openDialog('delete');
      break;
    case 'delete-confirm': {
      const categories = this.state.categories.filter(entry => entry.id !== category.id);
      this.closeDialog({ categories, selectedCategoryId: categories[Math.min(categoryIndex, categories.length - 1)]?.id || null, selectedItemId: null, previewQuery: '' }, this.focusCategory);
      break;
    }
    case 'item-select':
      this.setState({ selectedItemId: id });
      break;
    case 'item-prev':
    case 'item-next':
      this.changeCategory({ ...category, items: moveEntry(category.items, item.id, category.items.indexOf(item) + (action === 'item-prev' ? -1 : 1)) }, this.focusItem);
      break;
    case 'item-remove': {
      const next = removeItem(category, item.id);
      const index = category.items.indexOf(item);
      this.setState({ selectedItemId: next.items[Math.min(index, next.items.length - 1)]?.id || null });
      this.changeCategory(next, this.focusItem);
      break;
    }
    case 'item-copy':
      this.openDialog('copy');
      break;
    case 'copy-confirm': {
      const target = this.state.categories.find(entry => entry.id === id);

      if (target.items.some(entry => itemIdentity(entry) === itemIdentity(item)) || target.items.length >= MAX_CATEGORY_ITEMS || itemCount(this.state.categories) >= MAX_ITEMS) {
        break;
      }

      const copied = { ...item, id: uuid() };
      this.closeDialog({ categories: this.state.categories.map(entry => entry.id === target.id ? { ...target, items: [...target.items, copied] } : entry), resolvedItems: { ...this.state.resolvedItems, [copied.id]: this.state.resolvedItems[item.id] } });
      break;
    }
    case 'emoji-add':
      this.openDialog('add');
      break;
    case 'candidate-remove':
      this.setState(previous => ({ candidates: previous.candidates.filter(candidate => candidate.item.id !== id) }));
      break;
    case 'add-confirm': {
      if (this.state.resolving || !this.state.candidates.length) {
        break;
      }

      const added = this.state.candidates.filter(candidate => !category.items.some(entry => itemIdentity(entry) === itemIdentity(candidate.item)));
      const resolvedItems = { ...this.state.resolvedItems };
      added.forEach(candidate => {
        resolvedItems[candidate.item.id] = candidate.resolved;
      });
      this.closeDialog({
        categories: this.state.categories.map(entry => entry.id === category.id ? { ...category, items: [...category.items, ...added.map(candidate => candidate.item)] } : entry),
        resolvedItems,
        selectedItemId: added[0]?.item.id || null,
      }, this.focusItem);
      break;
    }
    case 'dialog-close':
      this.closeDialog();
      break;
    case 'discard':
    case 'reload':
      this.openDialog(action);
      break;
    case 'discard-confirm': {
      const reload = this.state.dialog === 'reload';
      this.closeDialog({}, () => {
        if (reload) {
          this.load();
        } else {
          this.acceptDocument(clone(this.savedDocument));
        }
      });
      break;
    }
    case 'preview':
      this.appearance?.scrollIntoView({ block: 'start' });
      this.appearance?.querySelector('[aria-pressed="true"]')?.focus({ preventScroll: true });
      break;
    case 'preview-personal':
    case 'preview-standard':
      this.setState({ previewMode: action === 'preview-personal' ? 'personal' : 'standard', previewQuery: '', previewSelection: null });
      break;
    default:
      break;
    }
  };

  button(action, key, options = {}) {
    return <EditorButton action={action} label={this.text(key)} onAction={this.handleAction} {...options} />;
  }

  renderCategoryArt(category) {
    const heading = categoryHeading(category, this.state.resolvedItems);
    return <EmojiArt image={heading.image} text={heading.text} />;
  }

  renderCategories() {
    const { categories, selectedCategoryId, dropTarget } = this.state;
    const index = categories.findIndex(category => category.id === selectedCategoryId);

    return (
      <section className='pes-categories' aria-label={this.text('categories')}>
        <div className='pes-section-head'><h3>{this.text('categories')}</h3>{this.button('category-add', 'categoryAdd', { icon: 'plus', iconOnly: true, disabled: categories.length >= MAX_CATEGORIES })}</div>
        <div className='pes-category-list'>
          {categories.map(category => (
            <div key={category.id} className={classNames('pes-category-row', { 'pes-current': category.id === selectedCategoryId, 'pes-drop-target': dropTarget === `category:${category.id}` })} draggable data-drag-kind='category' data-id={category.id} onDragStart={this.handleDragStart} onDragOver={this.handleDragOver} onDrop={this.handleDrop} onDragEnd={this.handleDragEnd}>
              <span className='pes-grip' aria-hidden='true'><Icon id='ellipsis-v' /></span>
              <button type='button' className='pes-category-button' data-action='category-select' data-id={category.id} onClick={this.handleAction} aria-pressed={category.id === selectedCategoryId} title={category.name || this.text('categoryUnnamed')}>
                {this.renderCategoryArt(category)}
                <span className='pes-category-name'>{category.name || this.text('categoryUnnamed')}</span>
                <span className='pes-count' aria-label={this.text('count', { count: category.items.length })}>{category.items.length}</span>
              </button>
            </div>
          ))}
          {categories.length === 0 && <p className='pes-hint'>{this.text('noCategories')}</p>}
        </div>
        <div className='pes-category-tools'>
          {this.button('category-up', 'categoryUp', { icon: 'arrow-up', iconOnly: true, disabled: index <= 0 })}
          {this.button('category-down', 'categoryDown', { icon: 'arrow-down', iconOnly: true, disabled: index < 0 || index >= categories.length - 1 })}
          {this.button('category-delete', 'categoryDelete', { icon: 'trash', iconOnly: true, disabled: index < 0 })}
        </div>
      </section>
    );
  }

  renderItemActions(category) {
    const item = this.currentItem();

    if (!item) {
      return null;
    }

    const index = category.items.indexOf(item);

    return (
      <div className='pes-item-actions'>
        <div className='pes-selected-info'>{itemLabel(item, this.state.resolvedItems)}<span className='pes-hint'>{item.kind === 'custom' ? `:${item.shortcode}:` : item.native}</span></div>
        <div className='pes-action-group'>
          {this.button('item-prev', 'emojiPrevious', { icon: 'arrow-left', iconOnly: true, disabled: index === 0 })}
          {this.button('item-next', 'emojiNext', { icon: 'arrow-right', iconOnly: true, disabled: index === category.items.length - 1 })}
        </div>
        {this.button('item-copy', 'emojiCopy', { icon: 'clone', className: 'pes-plain' })}
        {this.button('item-remove', 'emojiRemove', { icon: 'times', danger: true, className: 'pes-plain' })}
      </div>
    );
  }

  renderEditor() {
    const category = this.currentCategory();
    const { resolvedItems, selectedItemId, dropTarget } = this.state;

    if (!category) {
      return <section className='pes-editor'><div className='pes-empty'><Icon id='folder-open-o' aria-hidden='true' /><p>{this.text('categoryEmpty')}</p>{this.button('category-add', 'categoryAdd', { icon: 'plus' })}</div></section>;
    }

    const representative = representativeItem(category);
    const value = category.heading.mode === 'emoji' ? category.heading.item_id : `@${category.heading.mode}`;
    const full = category.items.length >= MAX_CATEGORY_ITEMS || itemCount(this.state.categories) >= MAX_ITEMS;

    return (
      <section className='pes-editor' aria-label={this.text('categoryEditor')}>
        <label className='pes-field'><span className='pes-field-label'>{this.text('categoryName')}</span><input ref={this.setNameRef} className='pes-input' value={category.name} onChange={this.handleName} autoComplete='off' name='category-name' aria-invalid={['categoryNameRequired', 'categoryNameInvalid'].includes(this.state.error)} /></label>
        <div className='pes-field'>
          <label htmlFor='personal-emoji-heading' className='pes-field-label'>{this.text('heading')}</label>
          <div className='pes-representative'>
            <span className='pes-rep-swatch'>{this.renderCategoryArt(category)}</span>
            {/* Immediate preview updates keep focus on this native select. */}
            {/* eslint-disable-next-line jsx-a11y/no-onchange */}
            <select className='pes-select' id='personal-emoji-heading' value={value} onChange={this.handleHeading}>
              <option value='@first'>{this.text('headingFirst')}</option>
              <option value='@initial'>{this.text('headingInitial', { initial: firstGrapheme(category.name.trim()) || '…' })}</option>
              <optgroup label={this.text('headingEmoji')}>
                {category.items.map(item => <option key={item.id} value={item.id} disabled={!resolvedItems[item.id]?.available && category.heading.item_id !== item.id}>{itemLabel(item, resolvedItems)}{resolvedItems[item.id]?.available ? '' : ` (${this.text('unavailable')})`}</option>)}
              </optgroup>
            </select>
          </div>
          <p className='pes-hint'>{this.text('headingHint')}</p>
        </div>
        <div className='pes-items-head'>
          <div className='pes-items-label'><h3>{this.text('registered')}</h3><span className='pes-count'>{this.text('count', { count: category.items.length })}</span></div>
          {this.button('emoji-add', 'emojiAdd', { icon: 'plus', disabled: full })}
        </div>
        {category.items.length ? (
          <React.Fragment>
            <div className='pes-grid' aria-label={this.text('registered')}>
              {category.items.map(item => {
                const resolved = resolvedItems[item.id];
                const label = itemLabel(item, resolvedItems);
                const heading = representative?.id === item.id;
                const unavailable = !resolved?.available;
                const description = [label, heading && this.text('isHeading'), unavailable && this.text('unavailable')].filter(Boolean).join(', ');

                return (
                  <button key={item.id} type='button' className={classNames('pes-emoji-tile', { 'pes-selected': item.id === selectedItemId, 'pes-unavailable': unavailable, 'pes-drop-target': dropTarget === `item:${item.id}` })} data-action='item-select' data-id={item.id} onClick={this.handleAction} draggable data-drag-kind='item' onDragStart={this.handleDragStart} onDragOver={this.handleDragOver} onDrop={this.handleDrop} onDragEnd={this.handleDragEnd} aria-pressed={item.id === selectedItemId} aria-label={description} title={description}>
                    {heading && <span className='pes-rep-mark' aria-hidden='true'>●</span>}
                    <EmojiArt image={resolved?.image} text={unavailable ? '—' : item.native} size={32} wide />
                    <span className='pes-tile-label'>{unavailable ? this.text('unavailable') : label}</span>
                  </button>
                );
              })}
            </div>
            <p className='pes-hint pes-reorder-hint'>{this.text('emojiMove')}</p>
          </React.Fragment>
        ) : (
          <div className='pes-empty'><Icon id='smile-o' aria-hidden='true' /><p>{this.text('emojiEmpty')}</p>{this.button('emoji-add', 'emojiAdd', { disabled: full })}</div>
        )}
        {full && <p className='pes-hint'>{this.text('limit')}</p>}
        {this.renderItemActions(category)}
      </section>
    );
  }

  stock() {
    if (!this.stockCache || this.stockCache.categories !== this.state.categories || this.stockCache.resolvedItems !== this.state.resolvedItems) {
      this.stockCache = { categories: this.state.categories, resolvedItems: this.state.resolvedItems, stock: draftStock(this.state.categories, this.state.resolvedItems) };
    }

    return this.stockCache.stock;
  }

  theme() {
    const light = document.body.classList.contains('theme-mastodon-light') || document.body.classList.contains('theme-system') && typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: light)').matches;
    return light ? 'light' : 'dark';
  }

  renderAppearance() {
    const { pickerSize, previewMode, previewQuery, selectedCategoryId, previewSelection } = this.state;
    const previewText = previewSelection ? (previewSelection.native || previewSelection.colons) : this.text('previewHint');

    return (
      <section className='pes-appearance' aria-labelledby='personal-emoji-appearance' ref={this.setAppearanceRef}>
        <div className='pes-appearance-controls'>
          <h3 id='personal-emoji-appearance'>{this.text('appearance')}</h3>
          <p className='pes-hint'>{this.text('appearanceHint')}</p>
          <div className='pes-size-control'>
            <div className='pes-size-label'><label className='pes-field-label' htmlFor='personal-emoji-size'>{this.text('size')}</label><output className='pes-size-value' htmlFor='personal-emoji-size'>{pickerSize} px</output></div>
            <input className='pes-range' type='range' id='personal-emoji-size' min={22} max={48} step={1} value={pickerSize} onChange={this.handleSize} aria-valuetext={this.text('sizeValue', { size: pickerSize })} />
            <div className='pes-range-labels' aria-hidden='true'><span>22 px</span><span>48 px</span></div>
          </div>
        </div>
        <section className='pes-preview-panel' aria-label={this.text('preview')}>
          <div className='pes-preview-heading'><h3>{this.text('preview')}</h3><span className='pes-hint'>{this.text('draft')}</span></div>
          <div className='pes-preview-picker'>
            <div className='pes-preview-mode'>
              <button type='button' data-action='preview-personal' onClick={this.handleAction} aria-pressed={previewMode === 'personal'}>{this.text('personal')}</button>
              <button type='button' data-action='preview-standard' onClick={this.handleAction} aria-pressed={previewMode === 'standard'}>{this.text('standard')}</button>
            </div>
            {previewMode === 'personal' ? (
              <StockEmojiPicker stock={this.stock()} status='ready' query={previewQuery} onQueryChange={this.handlePreviewQuery} onPick={this.handlePreviewPick} emojiSize={pickerSize} perLine={Math.floor(272 / (pickerSize + 12))} autoFocus={false} animate={Boolean(autoPlayEmoji)} theme={this.theme()} selectedCategoryId={selectedCategoryId} />
            ) : (
              <LazyStandardPicker load={this.props.loadStandardPicker} onPick={this.handlePreviewPick} emojiSize={pickerSize} theme={this.theme()} skinTone={this.state.previewSkinTone} onSkinToneChange={this.handlePreviewSkinTone} autoFocus={false} />
            )}
            <div className='pes-preview-info' aria-live='polite'>{previewText}</div>
          </div>
        </section>
      </section>
    );
  }

  renderAddDialog() {
    const { candidates, resolving, candidateError, candidateMessage } = this.state;

    return (
      <React.Fragment>
        <p className='pes-hint'>{this.text('emojiAddTo', { name: this.currentCategory().name })}</p>
        <p className='pes-hint pes-dialog-hint'>{this.text('selectionHint')}</p>
        <LazyStandardPicker load={this.props.loadStandardPicker} onPick={this.handleCandidatePick} emojiSize={22} theme={this.theme()} skinTone={this.state.addSkinTone} onSkinToneChange={this.handleAddSkinTone} autoFocus={false} showFrequentlyUsed />
        <div className='pes-candidates' aria-label={this.text('selected')}>
          {candidates.map(candidate => <button type='button' key={candidate.item.id} data-action='candidate-remove' data-id={candidate.item.id} className='pes-candidate-chip' onClick={this.handleAction} aria-label={`${this.text('emojiRemove')}: ${candidate.resolved.label}`}><EmojiArt image={candidate.resolved.image} text={candidate.item.native} size={24} /><span>{candidate.resolved.label}</span><Icon id='times' aria-hidden='true' /></button>)}
        </div>
        {resolving > 0 && <p className='pes-hint' role='status'>{this.text('resolving')}</p>}
        {candidateMessage && <p className='pes-hint' role='status'>{this.text(candidateMessage)}</p>}
        {candidateError && <p className='pes-notice' role='alert'>{this.text(candidateError)}</p>}
        <div className='pes-dialog-actions'>
          {this.button('dialog-close', 'cancel')}
          <EditorButton action='add-confirm' label={this.text('add', { count: candidates.length })} onAction={this.handleAction} disabled={resolving > 0 || candidates.length === 0} primary />
        </div>
      </React.Fragment>
    );
  }

  renderCopyDialog() {
    const item = this.currentItem();
    const destinations = this.state.categories.filter(category => category.id !== this.state.selectedCategoryId);

    return (
      <div className='pes-destinations'>
        {destinations.length === 0 && <p className='pes-hint'>{this.text('noDestination')}</p>}
        {destinations.map(category => {
          const exists = category.items.some(entry => itemIdentity(entry) === itemIdentity(item));
          const full = category.items.length >= MAX_CATEGORY_ITEMS || itemCount(this.state.categories) >= MAX_ITEMS;

          return <button key={category.id} type='button' data-action='copy-confirm' data-id={category.id} className='pes-button pes-destination' onClick={this.handleAction} disabled={exists || full}>{this.renderCategoryArt(category)}<span>{category.name}</span>{exists && <span className='pes-hint'>{this.text('alreadyAdded')}</span>}</button>;
        })}
      </div>
    );
  }

  renderDialog() {
    const { dialog } = this.state;

    if (!dialog) {
      return null;
    }

    const titles = { add: 'emojiAdd', copy: 'emojiCopy', delete: 'categoryDelete', discard: 'discardTitle', reload: 'discardTitle' };

    return (
      <div className='pes-dialog-layer'>
        <section ref={this.setDialogRef} className={classNames('pes-dialog', { 'pes-dialog--add': dialog === 'add' })} role='dialog' aria-modal='true' aria-labelledby='personal-emoji-dialog-title' onKeyDownCapture={this.handleDialogKeyDown}>
          <div className='pes-dialog-head'><h3 id='personal-emoji-dialog-title'>{this.text(titles[dialog])}</h3>{this.button('dialog-close', 'close', { icon: 'times', iconOnly: true })}</div>
          {dialog === 'add' && this.renderAddDialog()}
          {dialog === 'copy' && this.renderCopyDialog()}
          {dialog === 'delete' && <React.Fragment><p>{this.text('categoryDeleteBody', { name: this.currentCategory().name })}</p><div className='pes-dialog-actions'>{this.button('dialog-close', 'cancel')}{this.button('delete-confirm', 'delete', { danger: true })}</div></React.Fragment>}
          {(dialog === 'discard' || dialog === 'reload') && <React.Fragment><p>{this.text('discardBody')}</p><div className='pes-dialog-actions'>{this.button('dialog-close', 'cancel')}{this.button('discard-confirm', dialog === 'reload' ? 'reload' : 'discard', { danger: true })}</div></React.Fragment>}
        </section>
      </div>
    );
  }

  render() {
    const { status, saving, error, dialog } = this.state;
    const dirty = this.dirty();
    let saveState = dirty ? 'dirty' : 'saved';

    if (saving) {
      saveState = 'saving';
    }

    if (status !== 'ready') {
      return <div className='personal-emoji-sets pes-empty' role='status'><p>{this.text(status === 'error' ? 'loadError' : 'loading')}</p>{status === 'error' && <button type='button' className='pes-button' onClick={this.load}>{this.text('retry')}</button>}</div>;
    }

    return (
      <div className='personal-emoji-sets' ref={this.setRootRef}>
        <div ref={this.setProductRef} aria-hidden={dialog ? true : undefined}>
          <header className='pes-page-head'>
            <p className='pes-subtitle'>{this.text('subtitle')}</p>
            <div className='pes-head-actions'>{this.button('preview', 'preview', { icon: 'eye' })}{this.button('discard', 'discard', { disabled: !dirty || saving })}{this.button('save', saving ? 'saving' : 'save', { primary: true, disabled: !dirty || saving })}</div>
          </header>
          <div className={classNames('pes-save-status', { 'pes-dirty': dirty })} role='status' aria-live='polite'>
            {dirty ? <span className='pes-dot' /> : <Icon id='check' aria-hidden='true' />}<span>{this.text(saveState)}</span>
          </div>
          {error && <div className='pes-notice' role='alert'><p>{this.text(error)}</p>{error === 'conflict' && this.button('reload', 'reload')}</div>}
          <fieldset className='pes-edit-fields' disabled={saving} aria-busy={saving}>
            <div className='pes-workspace'>{this.renderCategories()}{this.renderEditor()}</div>
            {this.renderAppearance()}
          </fieldset>
          <footer className='pes-footer'>{this.text('footer')}</footer>
        </div>
        {this.renderDialog()}
      </div>
    );
  }

}

export default injectIntl(PersonalEmojiSetEditor);
