jest.mock('react-intl', () => {
  const React = require('react');
  const formatMessage = ({ defaultMessage }) => defaultMessage;

  return {
    defineMessages: (messages) => messages,
    injectIntl: (Component) => (props) => React.createElement(Component, { ...props, intl: { formatMessage } }),
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import React from 'react';
import { fireEvent, render, screen } from '@testing-library/react';
import GroupDirectoryFilterForm from '../components/filter_form';

const renderForm = (props) => render(
  <GroupDirectoryFilterForm
    viewKey={props.viewKey}
    params={{ order: 'active', scope: 'all', software: '', q: '', ...props.params }}
    signedIn={props.signedIn}
    onChange={props.onChange}
  />,
);

describe('GroupDirectoryFilterForm', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('keeps two columns on separate controls and commits search after a short pause', () => {
    const onLeft = jest.fn();
    const onRight = jest.fn();
    render(
      <div>
        <GroupDirectoryFilterForm viewKey='column:left' params={{ order: 'active', scope: 'all', software: '', q: '' }} signedIn onChange={onLeft} />
        <GroupDirectoryFilterForm viewKey='column:right' params={{ order: 'new', scope: 'local', software: '', q: 'books' }} signedIn onChange={onRight} />
      </div>,
    );

    const orders = screen.getAllByRole('radio', { name: 'Newly found', hidden: true });
    expect(orders).toHaveLength(2);
    expect(orders[0].name).not.toEqual(orders[1].name);
    expect(orders[0].checked).toBe(false);
    expect(orders[1].checked).toBe(true);
    expect(screen.queryByRole('combobox', { name: 'Implementation' })).toBeNull();

    fireEvent.click(screen.getAllByRole('button', { name: 'More filters' })[0]);
    expect(screen.getAllByRole('combobox', { name: 'Implementation' })).toHaveLength(1);

    fireEvent.click(orders[0]);
    expect(onLeft).toHaveBeenCalledWith({ order: 'new' });
    expect(onRight).not.toHaveBeenCalled();

    const search = screen.getAllByRole('searchbox', { name: 'Search groups' })[0];
    fireEvent.change(search, { target: { value: '写真' } });
    expect(onLeft).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(299);
    expect(onLeft).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(1);
    expect(onLeft).toHaveBeenCalledWith({ q: '写真' });

    fireEvent.change(search, { target: { value: '写真サークル' } });
    fireEvent.keyDown(search, { key: 'Enter' });
    expect(onLeft).toHaveBeenCalledWith({ q: '写真サークル' });
  });

  it('explains a one-character search and hides the note at two characters', () => {
    const onChange = jest.fn();
    renderForm({ viewKey: 'route', signedIn: true, onChange });
    const search = screen.getByRole('searchbox', { name: 'Search groups' });
    const note = 'Names and descriptions need at least 2 characters. One character matches a username exactly.';

    fireEvent.change(search, { target: { value: '猫' } });
    expect(screen.getByText(note)).toBeTruthy();
    expect(search.getAttribute('aria-describedby')).toEqual('group-directory-search-hint-route');
    jest.advanceTimersByTime(300);
    expect(onChange).toHaveBeenCalledWith({ q: '猫' });

    fireEvent.change(search, { target: { value: '猫好' } });
    expect(screen.queryByText(note)).toBeNull();
    expect(search.getAttribute('aria-describedby')).toBeNull();

    fireEvent.change(search, { target: { value: 'a' } });
    expect(screen.getByText(note)).toBeTruthy();

    fireEvent.change(search, { target: { value: '𠮷' } });
    expect(search.value).toHaveLength(2);
    expect(screen.getByText(note)).toBeTruthy();
    expect(search.getAttribute('aria-describedby')).toEqual('group-directory-search-hint-route');

    fireEvent.change(search, { target: { value: '𠮷好' } });
    expect(screen.queryByText(note)).toBeNull();
  });

  it('clears the search immediately and disables following when logged out', () => {
    const onChange = jest.fn();
    renderForm({ viewKey: 'route', signedIn: false, params: { q: 'books' }, onChange });

    const following = screen.getByRole('radio', { name: 'Following', hidden: true });
    expect(following.disabled).toBe(true);
    expect(following.closest('label').getAttribute('title')).toEqual('Log in to filter by groups you follow');

    fireEvent.change(screen.getByRole('searchbox', { name: 'Search groups' }), { target: { value: '' } });
    expect(onChange).toHaveBeenCalledWith({ q: '' });
  });

  it('clears unset when switching to an empty tag and queries only a finished tag', () => {
    const onChange = jest.fn();
    let language = 'unset';
    function handleChange(patch) {
      onChange(patch);
      if (Object.prototype.hasOwnProperty.call(patch, 'language')) {
        language = patch.language;
      }
    }
    const ui = () => (
      <GroupDirectoryFilterForm
        viewKey='route'
        params={{ order: 'active', scope: 'all', software: '', q: '', language }}
        signedIn
        onChange={handleChange}
      />
    );
    const { rerender } = render(ui());
    const mode = () => screen.getByRole('combobox', { name: 'Language' });
    expect(mode().value).toBe('unset');

    fireEvent.change(mode(), { target: { value: 'tag' } });
    expect(onChange).toHaveBeenLastCalledWith({ language: '' });
    expect(onChange).not.toHaveBeenCalledWith({ language: 'unset' });

    const tag = screen.getByRole('textbox', { name: 'Specific language tag' });
    fireEvent.change(tag, { target: { value: 'j' } });
    language = '';
    rerender(ui());
    jest.advanceTimersByTime(300);

    expect(onChange).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('combobox', { name: 'Language' }).value).toBe('tag');
    expect(screen.getByRole('textbox', { name: 'Specific language tag' }).value).toBe('j');
    expect(screen.getByRole('textbox', { name: 'Specific language tag' }).getAttribute('aria-invalid')).toBe('true');

    fireEvent.change(screen.getByRole('textbox', { name: 'Specific language tag' }), { target: { value: 'ja' } });
    jest.advanceTimersByTime(299);
    expect(onChange).toHaveBeenCalledTimes(1);
    jest.advanceTimersByTime(1);
    expect(onChange).toHaveBeenLastCalledWith({ language: 'ja' });
    language = 'ja';
    rerender(ui());
    expect(screen.getByRole('textbox', { name: 'Specific language tag' }).value).toBe('ja');
    expect(screen.getByText('A 2–3 letter language, then up to 3 subtags of 2–8 letters or digits, such as ja, en-US, or zh-Hans. Not every BCP 47 tag.')).toBeTruthy();

    fireEvent.change(screen.getByRole('combobox', { name: 'Language' }), { target: { value: 'all' } });
    expect(onChange).toHaveBeenLastCalledWith({ language: '' });
    language = '';
    rerender(ui());
    expect(screen.getByRole('combobox', { name: 'Language' }).value).toBe('all');
    expect(screen.queryByRole('textbox', { name: 'Specific language tag' })).toBeNull();
  });

  it('follows an external reset from unset to no language without querying again', () => {
    const onChange = jest.fn();
    const params = { order: 'active', scope: 'all', software: '', q: '', language: 'unset' };
    const { rerender } = renderForm({ viewKey: 'saved', signedIn: true, params, onChange });

    expect(screen.getByRole('combobox', { name: 'Language' }).value).toBe('unset');

    rerender(
      <GroupDirectoryFilterForm
        viewKey='saved'
        params={{ ...params, language: '' }}
        signedIn
        onChange={onChange}
      />,
    );

    expect(screen.getByRole('combobox', { name: 'Language' }).value).toBe('all');
    expect(screen.queryByRole('textbox', { name: 'Specific language tag' })).toBeNull();
    expect(onChange).not.toHaveBeenCalled();
  });
});
