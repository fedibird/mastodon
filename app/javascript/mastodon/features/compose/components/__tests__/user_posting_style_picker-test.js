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

import UserPostingStylePicker, { IntlUserPostingStyleCatalogNotice } from '../user_posting_style_picker';

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

  it('distinguishes a network failure from an unsupported destination and retries outside the menu', () => {
    const onRetry = jest.fn();
    const { rerender } = render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='failed'
        destinationFailure='error'
        visibilityConflict={false}
        onSelect={jest.fn()}
        onRetry={onRetry}
      />,
    );

    expect(screen.getByText('Couldn’t reach the destination. Choose the style again or retry.')).toBeTruthy();
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
    expect(onRetry).toHaveBeenCalledTimes(1);

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='failed'
        destinationFailure='unsupported'
        visibilityConflict={false}
        onSelect={jest.fn()}
        onRetry={onRetry}
      />,
    );

    expect(screen.getByText('This destination isn’t supported, so you can’t post.')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Retry' })).toBeTruthy();
  });

  it('names the empty option for a fixed destination separately from the style', () => {
    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        emptyLabel='place'
        compact
        onSelect={jest.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'This place only' }));

    const place = screen.getByRole('menuitemradio', { name: 'This place only' });
    const circle = screen.getByRole('menuitemradio', { name: /サークル告知/ });

    expect(place).toHaveAttribute('aria-checked', 'true');
    expect(circle).toHaveAttribute('aria-checked', 'false');
    expect(screen.getByText('Destination localsquad')).toBeTruthy();
    expect(screen.getByText('サークル告知').className).toContain('compose-form__style-name');
  });

  const defaultProps = {
    showDefaults: true,
    assignmentFetchStatus: 'ready',
    assignmentStatus: 'unset',
    assignmentStyleId: null,
    assignmentFailure: null,
    onSaveDefault: jest.fn(),
    onUseNoStyle: jest.fn(),
    onResetDefault: jest.fn(),
    onRetryAssignment: jest.fn(),
  };

  it('keeps place defaults outside the style radio group', () => {
    const onSelect = jest.fn();
    const onSaveDefault = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={onSelect}
        {...defaultProps}
        onSaveDefault={onSaveDefault}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /サークル告知/ }));

    const useHere = screen.getByRole('button', { name: 'Always use this style here' });
    const radios = screen.getAllByRole('menuitemradio').map(item => item.textContent);

    expect(useHere.getAttribute('role')).toBeNull();
    expect(radios.some(text => text.includes('Always use this style here'))).toBe(false);
    expect(screen.getByRole('button', { name: 'Don’t use a style here' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Return to automatic selection' })).toHaveAttribute('aria-pressed', 'true');

    fireEvent.click(useHere);

    expect(onSaveDefault).toHaveBeenCalledWith('1');
    expect(onSelect).not.toHaveBeenCalled();
  });

  it('shows a saved default and does not present a failed save as success', () => {
    const { rerender } = render(
      <UserPostingStylePicker
        styles={styles}
        selectedId='1'
        snapshot={styles.get(0)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentStatus='style'
        assignmentStyleId='1'
      />,
    );

    expect(screen.getByText('This place uses this style by default')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Always use this style here' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: 'Always use this style here' })).toBeDisabled();

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='2'
        snapshot={styles.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='saving'
        assignmentStatus='unset'
      />,
    );

    expect(screen.getByText('Saving the default for this place')).toBeTruthy();
    expect(screen.queryByText('This place uses this style by default')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Always use this style here' })).toBeDisabled();

    rerender(
      <UserPostingStylePicker
        styles={styles}
        selectedId='2'
        snapshot={styles.get(1)}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        emptyLabel='place'
        compact
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='ready'
        assignmentFailure='save'
        assignmentStatus='unset'
      />,
    );

    expect(screen.getByText('Couldn’t save the default for this place.')).toBeTruthy();
    expect(screen.queryByText('This place uses this style by default')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Always use this style here' }).getAttribute('role')).toBeNull();
    expect(document.querySelector('.compose-form__style--compact')).toBeTruthy();
    expect(screen.getByRole('button', { name: /読書メモ/ })).toBeTruthy();
  });

  it('offers a reload when the place default could not be loaded', () => {
    const onRetryAssignment = jest.fn();

    render(
      <UserPostingStylePicker
        styles={styles}
        selectedId={null}
        snapshot={null}
        unapplied={ImmutableList()}
        destinationStatus='idle'
        visibilityConflict={false}
        onSelect={jest.fn()}
        {...defaultProps}
        assignmentFetchStatus='failed'
        assignmentFailure='fetch'
        assignmentStatus={null}
        onRetryAssignment={onRetryAssignment}
      />,
    );

    expect(screen.queryByText('This place does not use a style')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: 'Reload the default for this place' }));
    expect(onRetryAssignment).toHaveBeenCalledTimes(1);
  });

  it('offers a way to reload posting styles after the catalog request fails', () => {
    const onRetry = jest.fn();

    render(<IntlUserPostingStyleCatalogNotice onRetry={onRetry} />);

    expect(screen.getByText('Couldn’t load posting styles.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Reload posting styles' }));
    expect(onRetry).toHaveBeenCalledTimes(1);
  });
});
