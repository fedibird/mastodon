import { defineMessages } from 'react-intl';

export const messages = defineMessages({
  genericName: { id: 'external_source.generic_name', defaultMessage: 'External content' },
  ownerLabel: { id: 'privacy.external.short', defaultMessage: 'External content (only you)' },
  byline: { id: 'external_source.byline', defaultMessage: 'by {name}' },
  openSite: { id: 'external_source.open_site', defaultMessage: 'Open {name}' },
  reader: { id: 'external_source.reader', defaultMessage: 'External content from {name} ({service}), only visible to you' },
  readerWithByline: { id: 'external_source.reader_with_byline', defaultMessage: 'External content from {name} ({service}) by {author}, only visible to you' },
});
