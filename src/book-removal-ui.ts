type CurrentBookRemovalAction =
  | "keep-current"
  | "open-first-remaining"
  | "show-empty-home";

interface BookRemovalUIState {
  removingCurrentBook: boolean;
  remainingBookCount: number;
  homeWasOpen: boolean;
  menuWasOpen: boolean;
}

interface BookRemovalUIActions {
  currentBookAction: CurrentBookRemovalAction;
  renderHome: boolean;
  reopenBookMenu: boolean;
}

export function decideBookRemovalUI(state: BookRemovalUIState): BookRemovalUIActions {
  if (state.removingCurrentBook) {
    return {
      currentBookAction: state.remainingBookCount > 0
        ? "open-first-remaining"
        : "show-empty-home",
      renderHome: false,
      reopenBookMenu: false,
    };
  }

  return {
    currentBookAction: "keep-current",
    renderHome: state.homeWasOpen,
    reopenBookMenu: state.menuWasOpen,
  };
}
