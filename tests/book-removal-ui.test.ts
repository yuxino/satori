import assert from "node:assert/strict";
import test from "node:test";

import { decideBookRemovalUI } from "../src/book-removal-ui.ts";

test("removing a non-current book refreshes an open home view", () => {
  assert.deepEqual(
    decideBookRemovalUI({
      removingCurrentBook: false,
      remainingBookCount: 1,
      homeWasOpen: true,
      menuWasOpen: false,
    }),
    {
      currentBookAction: "keep-current",
      renderHome: true,
      reopenBookMenu: false,
    },
  );
});

test("removing a non-current book reopens a menu that was open before confirmation", () => {
  assert.deepEqual(
    decideBookRemovalUI({
      removingCurrentBook: false,
      remainingBookCount: 2,
      homeWasOpen: false,
      menuWasOpen: true,
    }),
    {
      currentBookAction: "keep-current",
      renderHome: false,
      reopenBookMenu: true,
    },
  );
});

test("non-current removal can refresh home and the book menu together", () => {
  assert.deepEqual(
    decideBookRemovalUI({
      removingCurrentBook: false,
      remainingBookCount: 2,
      homeWasOpen: true,
      menuWasOpen: true,
    }),
    {
      currentBookAction: "keep-current",
      renderHome: true,
      reopenBookMenu: true,
    },
  );
});

test("removing the current book opens the first remaining book", () => {
  assert.deepEqual(
    decideBookRemovalUI({
      removingCurrentBook: true,
      remainingBookCount: 1,
      homeWasOpen: true,
      menuWasOpen: true,
    }),
    {
      currentBookAction: "open-first-remaining",
      renderHome: false,
      reopenBookMenu: false,
    },
  );
});

test("removing the last current book shows the empty home view", () => {
  assert.deepEqual(
    decideBookRemovalUI({
      removingCurrentBook: true,
      remainingBookCount: 0,
      homeWasOpen: false,
      menuWasOpen: true,
    }),
    {
      currentBookAction: "show-empty-home",
      renderHome: false,
      reopenBookMenu: false,
    },
  );
});
