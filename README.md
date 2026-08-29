# Safahat Library — KOReader plugin

Browse and download free Arabic e-books from [safahat.org](https://www.safahat.org),
the Hindawi Foundation's non-profit online library, directly from your
e-reader.

## Install

1. Copy the whole `safahat.koplugin` folder (not just the files inside it)
   onto your device, into KOReader's `plugins` directory:
   - `koreader/plugins/safahat.koplugin/`
2. Restart KOReader.
3. Open the main menu → **Safahat Library**.

## Use

- **Browse catalog** — shows the site's category list (all books + each
  subject with its book count, matching the site's own menu). Tap a
  category to see its books.
- **Search** — type a keyword/title. Confirmed: this POSTs to the
  site's real search form (`/layout/search/`, field name `keyword`),
  not a guessed URL.
- Tapping a book fetches its page and shows its title/author with a
  **Download EPUB** button.
- After downloading, you're offered to open the book immediately.
- **Download folder…** lets you change where files (and cached covers)
  are saved.

## What's confirmed vs. still a guess

Two parts are based on real markup pulled from the live site and
should work as-is:

- **Book detail pages** (title, author, cover, EPUB link) — confirmed.
- **The category sidebar** — confirmed.
- **A category's book grid** (the list of books shown after tapping a
  category) — confirmed, including handling the case where a book's
  id appears more than once on the page (e.g. a title block plus a
  separate counter/badge reusing the same link) by merging every
  match instead of trusting only the first one seen, and handling the
  site's inconsistent use of `'single'` vs `"double"` quotes in its
  own HTML (both are matched).
- **Search** — confirmed: it's a plain POST form to `/layout/search/`
  with a `keyword` field, not a guessed URL.

One thing is still unconfirmed: pagination within a long category
(`findNextPageUrl` follows a `rel="next"` / "next page" link if one is
found in the page).

All of the relevant functions (`parseBookList`, `parseCategories`,
`parseBookDetail`, `findNextPageUrl`) are short, separate, and
commented in `main.lua`.

### Debugging tips

- Every page this plugin fetches is saved as plain text under
  `<download folder>/debug/` (e.g. `catalog_<timestamp>.txt`,
  `categories_<timestamp>.txt`, `book_<id>.txt`). Open KOReader's file
  manager and look there to see exactly what the plugin received.
- Any Lua error during a callback now shows as a readable dialog with
  the error text instead of crashing, and is also logged to
  KOReader's `crash.log` (Menu → More tools → Show crash log), prefixed
  `Safahat:`. (Note this only catches errors raised synchronously
  inside a callback — a crash during KOReader's async paint pass,
  which is what an unsupported image format triggers, can't be caught
  this way; that's why the cover viewer was removed rather than kept
  behind a pcall.)

## Notes

- Downloads go through HTTPS using KOReader's bundled LuaSocket/LuaSec.
  Redirects are followed manually (with cookies carried along), since
  KOReader's bundled libraries don't support automatic redirects.
- No login or account is required — safahat.org's books are free to
  download.

