import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import MixEditorForm from '../components/editor_form';
import SourceForm from '../components/source_form';

const intl = {
  formatMessage: (message) => message.defaultMessage,
};

const acceptSource = () => true;
const rejectSource = () => false;
const emptySearch = () => Promise.resolve([]);

describe('mix editor form', () => {
  it('renames, reorders, removes, and saves the draft shown on screen', () => {
    const onTitleChange = jest.fn();
    const onRemoveSource = jest.fn();
    const onMoveSource = jest.fn();
    const onSave = jest.fn();
    const onCancel = jest.fn();
    const sources = [
      { type: 'home', params: {} },
      { type: 'public', title: 'Federated photos', params: { onlyMedia: true } },
    ];

    render(
      <MixEditorForm
        intl={intl}
        title='Desk'
        sources={sources}
        errors={[]}
        editing
        onTitleChange={onTitleChange}
        onAddSource={acceptSource}
        onRemoveSource={onRemoveSource}
        onMoveSource={onMoveSource}
        onSave={onSave}
        onCancel={onCancel}
        onDelete={jest.fn()}
        onSearch={emptySearch}
      />,
    );

    fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'Night' } });
    fireEvent.click(screen.getAllByRole('button', { name: 'Move source up' })[1]);
    fireEvent.click(screen.getAllByRole('button', { name: 'Remove source' })[0]);
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    fireEvent.submit(screen.getByRole('button', { name: 'Save' }).closest('form'));

    expect(onTitleChange).toHaveBeenCalledWith('Night');
    expect(onMoveSource).toHaveBeenCalledWith(1, -1);
    expect(onRemoveSource).toHaveBeenCalledWith(0);
    expect(onCancel).toHaveBeenCalled();
    expect(onSave).toHaveBeenCalled();
    expect(screen.getByText('Federated photos')).toBeTruthy();
    expect(screen.getByText('Media only')).toBeTruthy();
  });

  it('shows a validation error without saving an incomplete mix', () => {
    render(
      <MixEditorForm
        intl={intl}
        title=''
        sources={[]}
        errors={['sources_too_few', 'title_blank']}
        onTitleChange={jest.fn()}
        onAddSource={rejectSource}
        onRemoveSource={jest.fn()}
        onMoveSource={jest.fn()}
        onSave={jest.fn()}
        onCancel={jest.fn()}
        onSearch={emptySearch}
      />,
    );

    expect(screen.getByRole('alert')).toHaveTextContent('Add at least two sources.');
    expect(screen.getByRole('alert')).toHaveTextContent('Enter a name.');
  });
});

describe('mix source form', () => {
  it('adds a hashtag source and ignores a stale search response', async () => {
    const onAddSource = jest.fn(() => true);
    let resolveFirst;
    const first = new Promise(resolve => {
      resolveFirst = resolve;
    });
    const onSearch = jest.fn()
      .mockReturnValueOnce(first)
      .mockReturnValueOnce(Promise.resolve([{ type: 'hashtag', id: 'ruby', title: '#ruby' }]));

    render(<SourceForm intl={intl} lists={[]} onAddSource={onAddSource} onSearch={onSearch} />);

    fireEvent.change(screen.getByLabelText('Source type'), { target: { value: 'hashtag' } });
    fireEvent.change(screen.getByLabelText('Hashtag'), { target: { value: 'old' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    fireEvent.change(screen.getByLabelText('Hashtag'), { target: { value: 'ruby' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));

    expect(await screen.findByRole('button', { name: '#ruby' })).toBeTruthy();
    resolveFirst([{ type: 'hashtag', id: 'old', title: '#old' }]);
    await Promise.resolve();

    expect(screen.queryByRole('button', { name: '#old' })).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: '#ruby' }));
    fireEvent.change(screen.getByLabelText('Any of these'), { target: { value: 'web, api' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add source' }));

    expect(onAddSource).toHaveBeenCalledWith(expect.objectContaining({
      type: 'hashtag',
      id: 'ruby',
      title: '#ruby',
      params: expect.objectContaining({ any: ['web', 'api'] }),
    }));
    expect(screen.getByLabelText('Hashtag')).toHaveValue('');
  });

  it('does not keep showing search results after the source type changes', async () => {
    let resolveSearch;
    const onSearch = jest.fn(() => new Promise(resolve => {
      resolveSearch = resolve;
    }));

    render(<SourceForm intl={intl} onAddSource={acceptSource} onSearch={onSearch} />);
    fireEvent.change(screen.getByLabelText('Source type'), { target: { value: 'account' } });
    fireEvent.change(screen.getByLabelText('Search'), { target: { value: 'ada' } });
    fireEvent.click(screen.getByRole('button', { name: 'Search' }));
    fireEvent.change(screen.getByLabelText('Source type'), { target: { value: 'home' } });
    resolveSearch([{ type: 'account', id: '5', title: 'ada@example.com' }]);
    await Promise.resolve();

    expect(screen.queryByRole('button', { name: 'ada@example.com' })).toBeNull();
  });
});
