/* eslint-disable react/prop-types, react/jsx-no-bind */

import React from 'react';
import { IntlProvider } from 'react-intl';
import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import Editor from '..';

const entry = (id, native) => ({ id, kind: 'unicode', native, emoji_id: '+1' });
const resolved = (native, label = native) => ({ available: true, label, image: { src: '/emoji/1f44d.svg', alt: native }, search: [label], selection: { id: '+1', custom: false, native } });
const fixture = () => ({
  revision: 3,
  picker_emoji_size: 22,
  categories: [
    { id: 'greeting', name: 'Greetings', heading: { mode: 'emoji', item_id: 'dark' }, items: [entry('light', '👍🏻'), entry('dark', '👍🏿')] },
    { id: 'wide', name: '横長', heading: { mode: 'initial' }, items: [{ id: 'banner', kind: 'custom', custom_emoji_id: '42', shortcode: 'banner' }] },
  ],
  resolved_items: { light: resolved('👍🏻', 'Light thumb'), dark: resolved('👍🏿', 'Dark thumb'), banner: { available: false, label: 'Old banner', reason: 'unavailable' } },
  stock: { categories: [] },
});

const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => {
    resolve = yes; reject = no;
  });
  return { promise, resolve, reject };
};

const FakeStandard = ({ onPick, emojiSize }) => <div><span>Standard size {emojiSize}</span><button type='button' onClick={() => onPick({ id: 'wave', custom: false, native: '👋🏽' })}>Pick wave</button><button type='button' onClick={() => onPick({ id: 'woman-technologist', custom: false, native: '👩🏽‍💻' })}>Pick technologist</button><button type='button' onClick={() => onPick({ id: 'banner', custom: true, colons: ':banner:' })}>Pick banner</button></div>;

function setup(props = {}) {
  const options = {
    loadDocument: jest.fn().mockResolvedValue(fixture()),
    saveDocument: jest.fn(),
    resolveEmoji: jest.fn(),
    loadStandardPicker: jest.fn().mockResolvedValue({ default: FakeStandard }),
    onSaved: jest.fn(),
    ...props,
  };
  const view = render(<IntlProvider locale='en'><Editor {...options} /></IntlProvider>);
  return { ...view, ...options };
}

const editor = () => within(screen.getByRole('region', { name: 'Selected category' }));
const categories = () => within(screen.getByRole('region', { name: 'Categories' }));
const ready = () => screen.findByLabelText('Category name');

afterEach(() => {
  document.body.style.overflow = '';
});

it('edits headings and size and searches registered stock without loading standard assets', async () => {
  const { loadStandardPicker } = setup();
  await ready();
  fireEvent.click(categories().getByRole('button', { name: /横長/ }));
  fireEvent.change(screen.getByLabelText('Category name'), { target: { value: 'Long' } });
  expect(screen.getByLabelText('Category heading')).toHaveValue('@initial');
  expect(screen.getByRole('option', { name: 'First character of the category name (L)' })).toBeInTheDocument();
  fireEvent.change(screen.getByLabelText('Emoji display size'), { target: { value: 48 } });
  expect(screen.getByLabelText('Emoji display size')).toHaveValue('48');
  expect(editor().getByRole('button', { name: /Old banner/ })).toHaveTextContent('Unavailable');
  expect(loadStandardPicker).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Standard' }));
  await screen.findByText('Standard size 48');
  expect(loadStandardPicker).toHaveBeenCalledTimes(1);
});

it('preserves an explicit heading across moves and clears it on removal, restoring focus to the next item', async () => {
  setup();
  await ready();
  fireEvent.click(editor().getByRole('button', { name: /Dark thumb/ }));
  fireEvent.click(editor().getByRole('button', { name: 'Move emoji earlier' }));
  expect(screen.getByLabelText('Category heading')).toHaveValue('dark');
  expect(editor().getByRole('button', { name: /Dark thumb/ })).toHaveFocus();
  fireEvent.click(editor().getByRole('button', { name: 'Remove' }));
  expect(screen.getByLabelText('Category heading')).toHaveValue('@first');
  expect(editor().getByRole('button', { name: /Light thumb/ })).toHaveFocus();
});

it('copies a placement with a new id and preserves the resolved skin tone through save', async () => {
  const saveDocument = jest.fn(request => Promise.resolve({ ...fixture(), revision: 4, categories: request.categories, picker_emoji_size: request.picker_emoji_size }));
  const { onSaved } = setup({ saveDocument });
  await ready();
  fireEvent.click(editor().getByRole('button', { name: /Dark thumb/ }));
  fireEvent.click(editor().getByRole('button', { name: 'Add to another category' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: '横長' }));
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1));
  const request = saveDocument.mock.calls[0][0];
  expect(request.expected_revision).toBe(3);
  expect(request.expected_picker_emoji_size).toBe(22);
  expect(request.categories[1].items[1].native).toBe('👍🏿');
  expect(request.categories[1].items[1].id).not.toBe('dark');
  expect(request.categories[1].heading).toEqual({ mode: 'initial' });
});

it('keeps draft data after conflict and requires an explicit discard before reloading', async () => {
  const error = Object.assign(new Error('conflict'), { status: 409 });
  const loadDocument = jest.fn().mockResolvedValue(fixture());
  const { saveDocument } = setup({ loadDocument, saveDocument: jest.fn().mockRejectedValue(error) });
  await ready();
  fireEvent.change(screen.getByLabelText('Category name'), { target: { value: 'My edited name' } });
  fireEvent.change(screen.getByLabelText('Emoji display size'), { target: { value: 48 } });
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await screen.findByRole('alert');
  expect(screen.getByLabelText('Category name')).toHaveValue('My edited name');
  expect(screen.getByLabelText('Emoji display size')).toHaveValue('48');
  expect(saveDocument.mock.calls[0][0].picker_emoji_size).toBe(48);
  fireEvent.click(screen.getByRole('button', { name: 'Reload saved version' }));
  expect(loadDocument).toHaveBeenCalledTimes(1);
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
  expect(screen.getByLabelText('Category name')).toHaveValue('My edited name');
  fireEvent.click(screen.getByRole('button', { name: 'Reload saved version' }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Reload saved version' }));
  await waitFor(() => expect(loadDocument).toHaveBeenCalledTimes(2));
  await waitFor(() => expect(screen.getByLabelText('Category name')).toHaveValue('Greetings'));
});

it('locks edits while saving and commits categories and size together', async () => {
  const saving = deferred();
  const { saveDocument } = setup({ saveDocument: jest.fn(() => saving.promise) });
  await ready();
  fireEvent.change(screen.getByLabelText('Category name'), { target: { value: 'Saved name' } });
  fireEvent.change(screen.getByLabelText('Emoji display size'), { target: { value: 36 } });
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(saveDocument).toHaveBeenCalledTimes(1));
  expect(screen.getByLabelText('Category name')).toBeDisabled();
  expect(screen.getByLabelText('Emoji display size')).toBeDisabled();
  expect(categories().getByRole('button', { name: 'Add category' })).toBeDisabled();
  const request = saveDocument.mock.calls[0][0];
  await act(async () => saving.resolve({ ...fixture(), revision: 4, categories: request.categories, picker_emoji_size: 36 }));
  expect(screen.getByLabelText('Category name')).toHaveValue('Saved name');
  expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled();
});

it('keeps candidate selection order when resolution completes out of order and adds the exact resolved native strings', async () => {
  const wave = deferred();
  const technologist = deferred();
  const resolveEmoji = jest.fn(request => request.native === '👋🏽' ? wave.promise : technologist.promise);
  const saveDocument = jest.fn(request => Promise.resolve({ ...fixture(), revision: 4, categories: request.categories }));
  setup({ resolveEmoji, saveDocument });
  await ready();
  fireEvent.click(editor().getByRole('button', { name: 'Add emoji' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Pick wave' }));
  fireEvent.click(screen.getByRole('button', { name: 'Pick technologist' }));
  await act(async () => technologist.resolve({ item: { kind: 'unicode', native: '👩🏽‍💻', emoji_id: 'female-technologist' }, resolved: resolved('👩🏽‍💻', 'Technologist') }));
  expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'Add (1)' })).toBeDisabled();
  await act(async () => wave.resolve({ item: { kind: 'unicode', native: '👋🏽', emoji_id: 'wave' }, resolved: resolved('👋🏽', 'Wave') }));
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Add (2)' }));
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(saveDocument).toHaveBeenCalledTimes(1));
  expect(saveDocument.mock.calls[0][0].categories[0].items.slice(-2).map(item => item.native)).toEqual(['👋🏽', '👩🏽‍💻']);
});

it('does not let a late candidate response change a closed dialog or a new selection', async () => {
  const waiting = deferred();
  setup({ resolveEmoji: jest.fn(() => waiting.promise) });
  await ready();
  fireEvent.click(editor().getByRole('button', { name: 'Add emoji' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Pick wave' }));
  fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape', isComposing: true, keyCode: 229 });
  expect(screen.getByRole('dialog')).toBeInTheDocument();
  fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  fireEvent.click(editor().getByRole('button', { name: 'Add emoji' }));
  await act(async () => waiting.resolve({ item: { kind: 'unicode', native: '👋🏽', emoji_id: 'wave' }, resolved: resolved('👋🏽', 'Wave') }));
  expect(within(screen.getByRole('dialog')).getByRole('button', { name: 'Add (0)' })).toBeDisabled();
});

it('adds a newly registered custom emoji with a reused shortcode while retaining the unavailable old identity', async () => {
  const newBanner = { item: { kind: 'custom', custom_emoji_id: '43', shortcode: 'banner' }, resolved: { ...resolved(':banner:', 'New banner'), selection: { id: 'banner', custom: true, native: ':banner:', colons: ':banner:' } } };
  const saveDocument = jest.fn(request => Promise.resolve({ ...fixture(), revision: 4, categories: request.categories }));
  const resolveEmoji = jest.fn().mockResolvedValue(newBanner);
  setup({ resolveEmoji, saveDocument });
  await ready();
  fireEvent.click(categories().getByRole('button', { name: /横長/ }));
  fireEvent.click(editor().getByRole('button', { name: 'Add emoji' }));
  fireEvent.click(await screen.findByRole('button', { name: 'Pick banner' }));
  const add = await screen.findByRole('button', { name: 'Add (1)' });
  expect(resolveEmoji).toHaveBeenCalledWith({ kind: 'custom', shortcode: 'banner' });
  fireEvent.click(add);
  expect(editor().getByRole('button', { name: /Old banner/ })).toHaveTextContent('Unavailable');
  expect(editor().getByRole('button', { name: /New banner/ })).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await waitFor(() => expect(saveDocument).toHaveBeenCalledTimes(1));
  expect(saveDocument.mock.calls[0][0].categories[1].items.map(item => item.custom_emoji_id)).toEqual(['42', '43']);
});

it('shows the category reported by server validation without discarding edits', async () => {
  const failure = Object.assign(new Error('Invalid'), { status: 422, errors: [{ path: 'categories.1.name', code: 'invalid_name' }] });
  setup({ saveDocument: jest.fn().mockRejectedValue(failure) });
  await ready();
  fireEvent.change(screen.getByLabelText('Category name'), { target: { value: 'Still here' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  await screen.findByText('Enter a category name of 1 to 60 characters.');
  expect(screen.getByLabelText('Category name')).toHaveValue('横長');
  expect(screen.getByLabelText('Category name')).toHaveFocus();
  fireEvent.click(categories().getByRole('button', { name: /Still here/ }));
  expect(screen.getByLabelText('Category name')).toHaveValue('Still here');
});

it('retries an initial load failure without creating or saving a set', async () => {
  const loadDocument = jest.fn().mockRejectedValueOnce(new Error('Offline')).mockResolvedValue(fixture());
  const { saveDocument } = setup({ loadDocument });
  fireEvent.click(await screen.findByRole('button', { name: 'Try again' }));
  await ready();
  expect(loadDocument).toHaveBeenCalledTimes(2);
  expect(saveDocument).not.toHaveBeenCalled();
});

it('permits an empty set and focuses the category name for a blank name validation error', async () => {
  const data = { ...fixture(), categories: [], resolved_items: {} };
  const { saveDocument } = setup({ loadDocument: jest.fn().mockResolvedValue(data) });
  await screen.findByText('Create your first category');
  fireEvent.click(categories().getByRole('button', { name: 'Add category' }));
  expect(screen.getByLabelText('Category name')).toHaveFocus();
  fireEvent.change(screen.getByLabelText('Category name'), { target: { value: '  ' } });
  fireEvent.click(screen.getByRole('button', { name: 'Save' }));
  expect(screen.getByRole('alert')).toHaveTextContent('Enter a name');
  expect(screen.getByLabelText('Category name')).toHaveFocus();
  expect(saveDocument).not.toHaveBeenCalled();
});
