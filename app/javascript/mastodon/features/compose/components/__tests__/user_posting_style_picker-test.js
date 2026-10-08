import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, fromJS } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

import UserPostingStylePicker from '../user_posting_style_picker';

const styles = ImmutableList([
  fromJS({
    id: '1',
    name: 'サークル告知',
    icon: '📣',
    purpose: 'サークル向けの告知',
    target: { kind: 'group', label: 'localsquad' },
  }),
  fromJS({
    id: '2',
    name: '読書メモ',
    icon: '📚',
    purpose: '読んだ本',
    target: { kind: 'hashtag', label: '#books' },
  }),
]);

describe('UserPostingStylePicker', () => {
  it('lists usual settings, saved styles, and the settings page', () => {
    const onSelect = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
      />,
    );

    expect(screen.getByText('Posting style')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Usual settings' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Usual settings' }));
    expect(screen.getByRole('menuitemradio', { name: /サークル告知/ })).toBeTruthy();
    expect(screen.getByText('サークル向けの告知')).toBeTruthy();
    expect(screen.getByText('Destination localsquad')).toBeTruthy();
    expect(screen.getByRole('link', { name: 'Posting style settings' }).getAttribute('href')).toEqual('/settings/user_posting_contexts');

    fireEvent.click(screen.getByRole('menuitemradio', { name: /読書メモ/ }));

    expect(onSelect).toHaveBeenCalledWith('2');
  });

  it('moves with the arrow keys, selects with Enter, and returns focus on Escape', () => {
    const onSelect = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'Usual settings' });

    fireEvent.click(trigger);

    const usual = screen.getByRole('menuitemradio', { name: 'Usual settings' });
    const circle = screen.getByRole('menuitemradio', { name: /サークル告知/ });

    expect(usual).toHaveAttribute('aria-checked', 'true');
    expect(circle).toHaveAttribute('aria-checked', 'false');
    expect(document.activeElement).toBe(usual);

    fireEvent.keyDown(usual, { key: 'ArrowDown' });

    expect(document.activeElement).toBe(circle);

    fireEvent.keyDown(circle, { key: 'Enter' });

    expect(onSelect).toHaveBeenCalledWith('1');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);

    fireEvent.click(trigger);
    expect(screen.getByRole('link', { name: 'Posting style settings' }).getAttribute('role')).toBeNull();
    fireEvent.keyDown(screen.getByRole('menu'), { key: 'Escape' });

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(document.activeElement).toBe(trigger);
  });
});
