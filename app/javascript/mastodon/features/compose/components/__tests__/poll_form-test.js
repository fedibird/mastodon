import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }, values) => (values ? defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]) : defaultMessage) }} />,
}));

import PollForm from '../poll_form';

describe('PollForm', () => {
  it('removes the whole poll from the form close button', () => {
    const onRemovePoll = jest.fn();

    render(
      <PollForm
        options={ImmutableList(['a', 'b'])}
        expiresIn={300}
        isMultiple={false}
        pollMaxOptions={4}
        suggestions={ImmutableList()}
        onChangeOption={jest.fn()}
        onAddOption={jest.fn()}
        onRemoveOption={jest.fn()}
        onChangeSettings={jest.fn()}
        onClearSuggestions={jest.fn()}
        onFetchSuggestions={jest.fn()}
        onSuggestionSelected={jest.fn()}
        onRemovePoll={onRemovePoll}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Remove poll' }));

    expect(onRemovePoll).toHaveBeenCalledTimes(1);
    expect(screen.getByDisplayValue('a')).toBeTruthy();
  });
});
