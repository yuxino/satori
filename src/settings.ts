import {
  credentialStatus,
  deleteProfileApiKey,
  saveProfileApiKey,
  testAIProfile,
  type AIProfile,
  type AIProviderKind,
  type CredentialStatus,
  type Settings,
} from "./api";

export interface OpenAISettingsOptions {
  settings: Settings;
  persistSettings(next: Settings): Promise<void>;
  onChange?(next: Settings): void;
  message?: string;
}

type BusyAction = "saving" | "testing" | "activating" | "deleting" | "credential";
type StatusTone = "neutral" | "success" | "warning" | "error" | "loading";
type FieldName = "name" | "base_url" | "model_id";

interface ProviderSpec {
  label: string;
  shortLabel: string;
  defaultName: string;
  baseURL: string;
  defaultModel: string;
  customURL: boolean;
}

interface ModelSuggestion {
  id: string;
  label: string;
  explanation: string;
}

interface CredentialState {
  phase: "loading" | "ready" | "error";
  saved: boolean;
  message?: string;
}

interface TestState {
  tone: StatusTone;
  label: string;
  message: string;
}

interface FocusSnapshot {
  id: string;
  selectionStart: number | null;
  selectionEnd: number | null;
}

interface ConfirmOptions {
  title: string;
  message: string;
  confirmLabel: string;
  danger?: boolean;
}

const MODEL_STUDIO_URL = "https://dashscope.aliyuncs.com/compatible-mode/v1";
const OPENAI_URL = "https://api.openai.com/v1";

const PROVIDERS: Record<AIProviderKind, ProviderSpec> = {
  model_studio: {
    label: "阿里云百炼",
    shortLabel: "百炼",
    defaultName: "阿里云百炼",
    baseURL: MODEL_STUDIO_URL,
    defaultModel: "qwen3-vl-plus",
    customURL: false,
  },
  open_ai: {
    label: "OpenAI",
    shortLabel: "OpenAI",
    defaultName: "OpenAI",
    baseURL: OPENAI_URL,
    defaultModel: "gpt-5.6-terra",
    customURL: false,
  },
  open_ai_compatible: {
    label: "OpenAI 兼容",
    shortLabel: "兼容",
    defaultName: "自定义连接",
    baseURL: "",
    defaultModel: "",
    customURL: true,
  },
};

const MODEL_SUGGESTIONS: Record<AIProviderKind, ModelSuggestion[]> = {
  model_studio: [
    {
      id: "qwen3-vl-plus",
      label: "Qwen3-VL Plus",
      explanation: "理解能力与速度均衡，适合日常教材讲解。",
    },
    {
      id: "qwen3-vl-flash",
      label: "Qwen3-VL Flash",
      explanation: "响应更快、费用更低，适合简单解释。",
    },
    {
      id: "qwen-vl-max",
      label: "Qwen-VL Max",
      explanation: "理解能力优先，适合更复杂的图文页面。",
    },
  ],
  open_ai: [
    {
      id: "gpt-5.6-terra",
      label: "GPT-5.6 Terra",
      explanation: "质量、速度与成本均衡，适合日常阅读。",
    },
    {
      id: "gpt-5.6-sol",
      label: "GPT-5.6 Sol",
      explanation: "质量优先，适合更困难的材料。",
    },
    {
      id: "gpt-5.6-luna",
      label: "GPT-5.6 Luna",
      explanation: "速度与成本优先，适合快速理解。",
    },
  ],
  open_ai_compatible: [],
};

let activeController: AISettingsController | null = null;

/**
 * 打开多 AI 连接设置。重复调用不会叠加弹窗：已打开时只更新调用方与提示，
 * 并把焦点带回现有对话框。
 */
export function openAISettings(options: OpenAISettingsOptions): void {
  if (activeController?.isConnected()) {
    activeController.updateOptions(options);
    return;
  }

  document.querySelector<HTMLElement>('#settings-modal[data-settings-controller="ai"]')?.remove();
  activeController = new AISettingsController(options, () => {
    activeController = null;
  });
}

class AISettingsController {
  private options: OpenAISettingsOptions;
  private baseline: Settings;
  private draft: Settings;
  private selectedProfileId: string;
  private readonly previousFocus: HTMLElement | null;
  private readonly overlay: HTMLDivElement;
  private readonly dialog: HTMLDivElement;
  private readonly messageBanner: HTMLDivElement;
  private readonly sidebar: HTMLElement;
  private readonly detail: HTMLElement;
  private readonly footer: HTMLElement;
  private readonly onDestroyed: () => void;
  private readonly credentialStates = new Map<string, CredentialState>();
  private readonly keyDrafts = new Map<string, string>();
  private readonly testStates = new Map<string, TestState>();
  private readonly fieldErrors = new Map<string, Partial<Record<FieldName, string>>>();
  private busy: BusyAction | null = null;
  private liveMessage = "";
  private liveTone: StatusTone = "neutral";
  private mounted = true;
  private appWasInert = false;
  private appAriaHidden: string | null = null;

  constructor(options: OpenAISettingsOptions, onDestroyed: () => void) {
    this.options = options;
    this.onDestroyed = onDestroyed;
    this.baseline = normalizeSettings(options.settings);
    this.draft = cloneSettings(this.baseline);
    this.selectedProfileId = resolveInitialProfileId(this.draft);
    this.previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;

    this.overlay = createElement("div", "settings-modal");
    this.overlay.id = "settings-modal";
    this.overlay.dataset.settingsController = "ai";

    this.dialog = createElement("div", "settings-window");
    this.dialog.setAttribute("role", "dialog");
    this.dialog.setAttribute("aria-modal", "true");
    this.dialog.setAttribute("aria-labelledby", "settings-dialog-title");
    this.dialog.setAttribute("aria-describedby", "settings-dialog-description");
    this.dialog.tabIndex = -1;

    const header = createElement("header", "settings-header");
    const heading = createElement("div", "settings-heading");
    const eyebrow = createElement("span", "settings-eyebrow", "SATORI");
    const title = createElement("h2", "settings-title", "设置");
    title.id = "settings-dialog-title";
    const description = createElement(
      "p",
      "settings-description",
      "在这台 Mac 上管理 AI 服务。密钥只保存在 macOS 钥匙串。",
    );
    description.id = "settings-dialog-description";
    heading.append(eyebrow, title, description);

    const closeButton = createButton("settings-icon-button", "关闭设置");
    closeButton.textContent = "×";
    closeButton.addEventListener("click", () => void this.requestClose());
    header.append(heading, closeButton);

    this.messageBanner = createElement("div", "settings-message");
    this.messageBanner.setAttribute("role", "note");

    const content = createElement("div", "settings-content");
    this.sidebar = createElement("aside", "settings-sidebar");
    this.sidebar.setAttribute("aria-label", "AI 服务连接");
    this.detail = createElement("main", "settings-detail");
    content.append(this.sidebar, this.detail);

    this.footer = createElement("footer", "settings-footer");
    this.dialog.append(header, this.messageBanner, content, this.footer);
    this.overlay.appendChild(this.dialog);

    this.overlay.addEventListener("mousedown", (event) => {
      if (event.target === this.overlay) void this.requestClose();
    });
    this.dialog.addEventListener("keydown", (event) => this.handleDialogKeyDown(event));

    this.makeBackgroundInert();
    document.body.appendChild(this.overlay);
    this.render(false);
    window.requestAnimationFrame(() => this.focusInitialControl());
    void this.loadCredentialStates();
  }

  isConnected(): boolean {
    return this.mounted && this.overlay.isConnected;
  }

  updateOptions(options: OpenAISettingsOptions): void {
    this.options = options;
    if (!this.isDirty() && !this.busy) {
      this.baseline = normalizeSettings(options.settings);
      this.draft = cloneSettings(this.baseline);
      this.selectedProfileId = resolveInitialProfileId(this.draft, this.selectedProfileId);
      this.seedMissingCredentialStates();
      this.render(true);
      void this.loadCredentialStates();
    } else {
      this.renderMessage();
    }
    this.dialog.focus({ preventScroll: true });
  }

  private render(preserveFocus = true): void {
    const focus = preserveFocus ? this.captureFocus() : null;
    this.renderMessage();
    this.renderSidebar();
    this.renderDetail();
    this.renderFooter();
    if (focus) this.restoreFocus(focus);
  }

  private renderMessage(): void {
    const message = this.options.message?.trim() ?? "";
    this.messageBanner.textContent = message;
    this.messageBanner.hidden = message.length === 0;
  }

  private renderSidebar(): void {
    this.sidebar.replaceChildren();

    const header = createElement("div", "settings-sidebar-header");
    const title = createElement("h3", "settings-sidebar-title", "AI 服务");
    const count = createElement("span", "settings-profile-count", `${this.draft.profiles.length} 个连接`);
    header.append(title, count);

    const list = createElement("div", "settings-profile-list");
    for (const profile of this.draft.profiles) {
      const selected = profile.id === this.selectedProfileId;
      const active = profile.id === this.draft.active_profile_id;
      const state = this.profileStatus(profile);

      const row = createButton("settings-profile-row", `编辑连接：${profile.name || "未命名连接"}`);
      row.setAttribute("aria-pressed", String(selected));
      if (selected) {
        row.id = "settings-selected-profile";
        row.classList.add("selected");
      }
      if (active) row.classList.add("active");
      row.addEventListener("click", () => {
        if (this.busy) return;
        this.selectedProfileId = profile.id;
        this.render(true);
        window.requestAnimationFrame(() => this.detail.querySelector<HTMLElement>("#settings-profile-name")?.focus());
      });

      const mark = createElement("span", "settings-provider-mark", providerSpec(profile.provider).shortLabel);
      mark.setAttribute("aria-hidden", "true");

      const copy = createElement("span", "settings-profile-copy");
      const topLine = createElement("span", "settings-profile-name");
      const name = createElement("span", "settings-profile-name-text", profile.name.trim() || "未命名连接");
      topLine.appendChild(name);
      if (active) {
        const activeBadge = createElement("span", "settings-active-badge", "当前");
        topLine.appendChild(activeBadge);
      }
      const meta = createElement(
        "span",
        "settings-profile-meta",
        `${providerSpec(profile.provider).label} · ${profile.model_id.trim() || "未填写模型"}`,
      );
      const status = createElement("span", "settings-profile-status", state.label);
      status.dataset.tone = state.tone;
      const dot = createElement("span", "settings-status-dot");
      dot.setAttribute("aria-hidden", "true");
      status.prepend(dot);
      copy.append(topLine, meta, status);
      row.append(mark, copy);
      list.appendChild(row);
    }

    const addButton = createButton("settings-add-profile", "添加 AI 服务连接");
    addButton.textContent = "+  添加连接";
    addButton.disabled = this.busy !== null;
    addButton.addEventListener("click", () => this.addProfile());

    this.sidebar.append(header, list, addButton);
  }

  private renderDetail(): void {
    this.detail.replaceChildren();
    const profile = this.selectedProfile();
    if (!profile) {
      const empty = createElement("div", "settings-detail-empty");
      const title = createElement("h3", "", "还没有 AI 服务");
      const description = createElement("p", "", "添加一个连接后，就可以选择服务商、模型和密钥。");
      empty.append(title, description);
      this.detail.appendChild(empty);
      return;
    }

    const spec = providerSpec(profile.provider);
    const detailHeader = createElement("div", "settings-detail-header");
    const identity = createElement("div", "settings-detail-identity");
    const mark = createElement("span", "settings-detail-mark", spec.shortLabel);
    mark.setAttribute("aria-hidden", "true");
    const identityCopy = createElement("div");
    const title = createElement("h3", "settings-detail-title", profile.name.trim() || "未命名连接");
    const subtitle = createElement("p", "settings-detail-subtitle", spec.label);
    identityCopy.append(title, subtitle);
    identity.append(mark, identityCopy);
    detailHeader.appendChild(identity);
    if (profile.id === this.draft.active_profile_id) {
      const activeBadge = createElement("span", "settings-current-badge", "当前使用");
      detailHeader.appendChild(activeBadge);
    }

    const form = createElement("form", "settings-form");
    form.id = "settings-profile-form";
    form.noValidate = true;
    form.addEventListener("submit", (event) => {
      event.preventDefault();
      void this.save();
    });

    const nameInput = document.createElement("input");
    nameInput.id = "settings-profile-name";
    nameInput.type = "text";
    nameInput.autocomplete = "off";
    nameInput.value = profile.name;
    nameInput.disabled = this.busy !== null;
    nameInput.addEventListener("input", () => {
      profile.name = nameInput.value;
      this.announce("", "neutral");
      this.clearFieldError(profile.id, "name", nameInput, "例如：日常阅读、公司代理或本地模型。");
      title.textContent = profile.name.trim() || "未命名连接";
      this.renderSidebar();
      this.renderFooter();
    });
    form.appendChild(this.buildField(profile, "name", "配置名称", nameInput, "例如：日常阅读、公司代理或本地模型。"));

    const providerSelect = document.createElement("select");
    providerSelect.id = "settings-provider";
    providerSelect.disabled = this.busy !== null;
    for (const provider of Object.keys(PROVIDERS) as AIProviderKind[]) {
      const option = document.createElement("option");
      option.value = provider;
      option.textContent = PROVIDERS[provider].label;
      option.selected = provider === profile.provider;
      providerSelect.appendChild(option);
    }
    providerSelect.addEventListener("change", () => {
      this.changeProvider(profile, providerSelect.value as AIProviderKind);
    });
    form.appendChild(
      this.buildField(
        profile,
        "provider",
        "服务类型",
        providerSelect,
        "预置服务使用固定官方地址；兼容服务可以填写自己的 API 地址。",
      ),
    );

    const baseInput = document.createElement("input");
    baseInput.id = "settings-base-url";
    baseInput.type = "url";
    baseInput.setAttribute("autocomplete", "url");
    baseInput.spellcheck = false;
    baseInput.value = profile.base_url;
    baseInput.readOnly = !spec.customURL;
    baseInput.disabled = this.busy !== null;
    baseInput.addEventListener("input", () => {
      profile.base_url = baseInput.value;
      this.announce("", "neutral");
      this.clearFieldError(
        profile.id,
        "base_url",
        baseInput,
        spec.customURL ? "填写 OpenAI 兼容 API 的根地址，必须以 http:// 或 https:// 开头。" : "官方地址由 Satori 管理。",
      );
      this.testStates.delete(profile.id);
      this.renderSidebar();
      this.renderFooter();
    });
    form.appendChild(
      this.buildField(
        profile,
        "base_url",
        "API 地址",
        baseInput,
        spec.customURL ? "填写 OpenAI 兼容 API 的根地址，必须以 http:// 或 https:// 开头。" : "官方地址由 Satori 管理。",
      ),
    );

    const modelInput = document.createElement("input");
    modelInput.id = "settings-model-id";
    modelInput.type = "text";
    modelInput.autocomplete = "off";
    modelInput.spellcheck = false;
    modelInput.value = profile.model_id;
    modelInput.disabled = this.busy !== null;
    const suggestions = MODEL_SUGGESTIONS[profile.provider];
    if (suggestions.length > 0) modelInput.setAttribute("list", "settings-model-suggestions");
    const modelHelp = this.modelExplanation(profile);
    modelInput.addEventListener("input", () => {
      profile.model_id = modelInput.value;
      this.announce("", "neutral");
      this.clearFieldError(profile.id, "model_id", modelInput);
      this.testStates.delete(profile.id);
      modelHelp.textContent = modelExplanationText(profile);
      this.renderSidebar();
      this.renderFooter();
    });
    const modelField = this.buildField(profile, "model_id", "模型", modelInput, "");
    modelField.querySelector(".settings-field-help")?.replaceWith(modelHelp);
    if (suggestions.length > 0) {
      const datalist = document.createElement("datalist");
      datalist.id = "settings-model-suggestions";
      for (const suggestion of suggestions) {
        const option = document.createElement("option");
        option.value = suggestion.id;
        option.label = suggestion.label;
        datalist.appendChild(option);
      }
      modelField.appendChild(datalist);
    }
    form.appendChild(modelField);

    if (spec.customURL) {
      const keyRequirement = createElement("label", "settings-switch-row");
      keyRequirement.htmlFor = "settings-api-key-required";
      const requirementCopy = createElement("span", "settings-switch-copy");
      const requirementTitle = createElement("span", "settings-switch-title", "需要 API Key");
      const requirementHelp = createElement(
        "span",
        "settings-switch-help",
        "关闭后不会发送 Authorization 请求头，适合本地或无需鉴权的服务。",
      );
      requirementCopy.append(requirementTitle, requirementHelp);
      const checkbox = document.createElement("input");
      checkbox.id = "settings-api-key-required";
      checkbox.type = "checkbox";
      checkbox.checked = profile.api_key_required;
      checkbox.disabled = this.busy !== null;
      checkbox.addEventListener("change", () => {
        profile.api_key_required = checkbox.checked;
        this.announce("", "neutral");
        this.testStates.delete(profile.id);
        this.render(true);
      });
      keyRequirement.append(requirementCopy, checkbox);
      form.appendChild(keyRequirement);
    }

    form.appendChild(this.buildCredentialPanel(profile));

    const testState = this.testStates.get(profile.id);
    if (testState) {
      const result = createElement("div", "settings-test-result");
      result.dataset.tone = testState.tone;
      result.setAttribute("role", testState.tone === "error" ? "alert" : "status");
      const resultTitle = createElement("strong", "", testState.label);
      const resultMessage = createElement("span", "", testState.message);
      result.append(resultTitle, resultMessage);
      form.appendChild(result);
    }

    const privacyNote = createElement(
      "p",
      "settings-test-note",
      "测试连接只发送一张内置的 1×1 测试图，不会上传你的书页，用来确认模型支持图片输入。",
    );
    form.appendChild(privacyNote);

    this.detail.append(detailHeader, form);
  }

  private renderFooter(): void {
    this.footer.replaceChildren();
    const profile = this.selectedProfile();

    const destructive = createElement("div", "settings-footer-destructive");
    const deleteButton = createButton("settings-button settings-button-danger", "删除当前连接");
    deleteButton.textContent = this.busy === "deleting" ? "正在删除…" : "删除连接…";
    deleteButton.disabled = !profile || this.draft.profiles.length <= 1 || this.busy !== null;
    if (this.draft.profiles.length <= 1) deleteButton.title = "至少保留一个连接";
    deleteButton.addEventListener("click", () => void this.deleteSelectedProfile());
    destructive.appendChild(deleteButton);

    const live = createElement("div", "settings-live", this.liveMessage);
    live.dataset.tone = this.liveTone;
    live.setAttribute("role", this.liveTone === "error" ? "alert" : "status");
    live.setAttribute("aria-live", this.liveTone === "error" ? "assertive" : "polite");
    live.setAttribute("aria-atomic", "true");

    const actions = createElement("div", "settings-footer-actions");
    const closeButton = createButton("settings-button", "关闭设置");
    closeButton.textContent = "关闭";
    closeButton.disabled = this.busy !== null;
    closeButton.addEventListener("click", () => void this.requestClose());

    const activateButton = createButton("settings-button", "设为当前使用的连接");
    const isActive = profile?.id === this.draft.active_profile_id;
    activateButton.textContent = this.busy === "activating" ? "正在切换…" : isActive ? "当前使用" : "设为当前";
    activateButton.disabled = !profile || isActive || this.busy !== null;
    activateButton.addEventListener("click", () => void this.activateSelectedProfile());

    const testButton = createButton("settings-button", "测试当前连接");
    testButton.textContent = this.busy === "testing" ? "正在测试…" : "测试连接";
    testButton.disabled = !profile || this.busy !== null;
    testButton.addEventListener("click", () => void this.testSelectedProfile());

    const saveButton = createButton("settings-button settings-button-primary", "保存全部更改");
    saveButton.type = "submit";
    saveButton.setAttribute("form", "settings-profile-form");
    saveButton.textContent = this.busy === "saving" ? "正在保存…" : "保存更改";
    saveButton.disabled = !this.isDirty() || this.busy !== null;
    saveButton.setAttribute("aria-busy", String(this.busy === "saving"));

    actions.append(closeButton, activateButton, testButton, saveButton);
    this.footer.append(destructive, live, actions);
  }

  private buildField(
    profile: AIProfile,
    field: FieldName | "provider",
    labelText: string,
    control: HTMLInputElement | HTMLSelectElement,
    helpText: string,
  ): HTMLDivElement {
    const wrapper = createElement("div", "settings-field");
    const label = createElement("label", "settings-field-label", labelText);
    label.htmlFor = control.id;
    const help = createElement("p", "settings-field-help", helpText);
    const helpId = `${control.id}-help`;
    help.id = helpId;
    control.setAttribute("aria-describedby", helpId);

    if (field !== "provider") {
      const error = this.fieldErrors.get(profile.id)?.[field];
      if (error) {
        control.setAttribute("aria-invalid", "true");
        help.textContent = error;
        help.classList.add("error");
      }
    }
    wrapper.append(label, control, help);
    return wrapper;
  }

  private modelExplanation(profile: AIProfile): HTMLParagraphElement {
    const help = createElement("p", "settings-field-help", modelExplanationText(profile));
    help.id = "settings-model-id-help";
    return help;
  }

  private buildCredentialPanel(profile: AIProfile): HTMLElement {
    const panel = createElement("section", "settings-credential-panel");
    panel.setAttribute("aria-labelledby", "settings-credential-title");

    const header = createElement("div", "settings-credential-header");
    const copy = createElement("div");
    const title = createElement("h4", "settings-credential-title", "API Key");
    title.id = "settings-credential-title";
    const subtitle = createElement("p", "settings-credential-subtitle", "已保存的 Key 不会回填到页面。");
    copy.append(title, subtitle);

    const state = this.credentialState(profile.id);
    const badge = createElement("span", "settings-credential-badge");
    badge.dataset.tone = state.phase === "error" ? "error" : state.phase === "loading" ? "loading" : state.saved ? "success" : "neutral";
    badge.textContent = credentialLabel(profile, state);
    badge.setAttribute("aria-live", "polite");
    header.append(copy, badge);

    const keyRow = createElement("div", "settings-key-row");
    const input = document.createElement("input");
    input.id = "settings-api-key";
    input.type = "password";
    input.autocomplete = "new-password";
    input.spellcheck = false;
    input.value = this.keyDrafts.get(profile.id) ?? "";
    input.placeholder = keyPlaceholder(profile, state);
    input.disabled = this.busy !== null || !profile.api_key_required;
    input.setAttribute("aria-label", state.saved ? "输入新的 API Key 以替换已保存的 Key" : "API Key");
    input.addEventListener("input", () => {
      this.keyDrafts.set(profile.id, input.value);
      this.announce("", "neutral");
      this.testStates.delete(profile.id);
      this.renderSidebar();
      this.renderFooter();
    });

    const revealButton = createButton("settings-key-action", "显示 API Key");
    revealButton.textContent = "显示";
    revealButton.disabled = input.disabled;
    revealButton.setAttribute("aria-pressed", "false");
    revealButton.addEventListener("click", () => {
      const reveal = input.type === "password";
      input.type = reveal ? "text" : "password";
      revealButton.textContent = reveal ? "隐藏" : "显示";
      revealButton.setAttribute("aria-label", reveal ? "隐藏 API Key" : "显示 API Key");
      revealButton.setAttribute("aria-pressed", String(reveal));
      input.focus();
    });
    keyRow.append(input, revealButton);

    if (state.saved) {
      const removeButton = createButton("settings-key-action settings-key-remove", "移除已保存的 API Key");
      removeButton.textContent = this.busy === "credential" ? "移除中…" : "移除";
      removeButton.disabled = this.busy !== null;
      removeButton.addEventListener("click", () => void this.removeSelectedCredential());
      keyRow.appendChild(removeButton);
    }

    const hint = createElement("p", "settings-credential-help");
    if (!profile.api_key_required) {
      hint.textContent = "此连接不会发送 Authorization 请求头；若钥匙串里已有 Key，可单独移除。";
    } else if (state.phase === "error") {
      hint.textContent = state.message ?? "无法读取钥匙串状态。你仍可以输入新的 Key 后重试保存。";
      hint.classList.add("error");
    } else if (state.saved) {
      hint.textContent = "输入新的 Key 并保存即可替换；留空不会改变已保存的 Key。";
    } else {
      hint.textContent = "Key 将按连接独立保存到 macOS 钥匙串，不会写入项目或设置文件。";
    }

    panel.append(header, keyRow, hint);
    return panel;
  }

  private profileStatus(profile: AIProfile): { tone: StatusTone; label: string } {
    if (!hasCompleteMetadata(profile)) return { tone: "warning", label: "信息未完成" };
    const keyDraft = this.keyDrafts.get(profile.id)?.trim();
    if (keyDraft) return { tone: "warning", label: "Key 待保存" };
    const test = this.testStates.get(profile.id);
    if (test) return { tone: test.tone, label: test.label };
    const credential = this.credentialState(profile.id);
    if (credential.phase === "loading") return { tone: "loading", label: "检查中" };
    if (credential.phase === "error") return { tone: "error", label: "钥匙串错误" };
    if (!profile.api_key_required) return { tone: "neutral", label: "无需 Key" };
    return credential.saved ? { tone: "success", label: "已保存 Key" } : { tone: "warning", label: "缺少 Key" };
  }

  private selectedProfile(): AIProfile | undefined {
    return this.draft.profiles.find((profile) => profile.id === this.selectedProfileId);
  }

  private credentialState(profileId: string): CredentialState {
    return this.credentialStates.get(profileId) ?? { phase: "loading", saved: false };
  }

  private seedMissingCredentialStates(): void {
    const ids = new Set(this.draft.profiles.map((profile) => profile.id));
    for (const profile of this.draft.profiles) {
      if (!this.credentialStates.has(profile.id)) {
        this.credentialStates.set(profile.id, { phase: "loading", saved: false });
      }
    }
    for (const id of this.credentialStates.keys()) {
      if (!ids.has(id)) this.credentialStates.delete(id);
    }
  }

  private async loadCredentialStates(): Promise<void> {
    this.seedMissingCredentialStates();
    this.render(true);
    const profiles = [...this.draft.profiles];
    await Promise.all(
      profiles.map(async (profile) => {
        try {
          const status: CredentialStatus = await credentialStatus(profile.id);
          if (!this.mounted || !this.draft.profiles.some((item) => item.id === profile.id)) return;
          this.credentialStates.set(profile.id, { phase: "ready", saved: status.saved });
        } catch (error) {
          if (!this.mounted) return;
          this.credentialStates.set(profile.id, {
            phase: "error",
            saved: false,
            message: `无法读取钥匙串：${formatError(error)}`,
          });
        }
        this.render(true);
      }),
    );
  }

  private changeProvider(profile: AIProfile, provider: AIProviderKind): void {
    if (!(provider in PROVIDERS)) return;
    const oldSpec = providerSpec(profile.provider);
    const newSpec = providerSpec(provider);
    const canRename = !profile.name.trim() || profile.name === oldSpec.defaultName || profile.name === "新的 AI 连接";
    profile.provider = provider;
    profile.base_url = newSpec.baseURL;
    profile.model_id = newSpec.defaultModel;
    profile.api_key_required = true;
    if (canRename) profile.name = newSpec.defaultName;
    this.fieldErrors.delete(profile.id);
    this.testStates.delete(profile.id);
    this.announce("", "neutral");
    this.render(true);
    window.requestAnimationFrame(() => this.detail.querySelector<HTMLElement>("#settings-provider")?.focus());
  }

  private addProfile(): void {
    if (this.busy) return;
    const profile: AIProfile = {
      id: `profile-${crypto.randomUUID()}`,
      name: nextProfileName(this.draft.profiles),
      provider: "open_ai_compatible",
      base_url: "",
      model_id: "",
      api_key_required: true,
    };
    this.draft.profiles.push(profile);
    this.selectedProfileId = profile.id;
    this.credentialStates.set(profile.id, { phase: "ready", saved: false });
    this.announce("已添加一个未保存的连接。请填写 API 地址和模型。", "neutral");
    this.render(false);
    window.requestAnimationFrame(() => {
      const input = this.detail.querySelector<HTMLInputElement>("#settings-profile-name");
      input?.focus();
      input?.select();
    });
  }

  private async save(): Promise<void> {
    if (this.busy || !this.isDirty()) return;
    if (!this.validateAllProfiles()) return;

    const next = normalizedDraft(this.draft);
    const pendingKeys = [...this.keyDrafts.entries()].filter(([, value]) => value.trim().length > 0);
    this.busy = "saving";
    this.announce("正在保存连接配置…", "loading");
    this.render(true);

    try {
      await this.options.persistSettings(cloneSettings(next));
      this.baseline = cloneSettings(next);
      this.draft = cloneSettings(next);
      this.selectedProfileId = resolveInitialProfileId(this.draft, this.selectedProfileId);

      const failures: string[] = [];
      for (const [profileId, key] of pendingKeys) {
        try {
          await saveProfileApiKey(profileId, key.trim());
          this.keyDrafts.delete(profileId);
          this.credentialStates.set(profileId, { phase: "ready", saved: true });
        } catch (error) {
          const profile = this.draft.profiles.find((item) => item.id === profileId);
          failures.push(`${profile?.name || "未命名连接"}：${formatError(error)}`);
          this.credentialStates.set(profileId, {
            phase: "error",
            saved: false,
            message: `密钥保存失败：${formatError(error)}`,
          });
        }
      }
      // persistSettings 会在 Key 写入前刷新一次调用方状态；这里再次通知，
      // 确保当前连接的新 Key 或被移除的 Key 立即反映到阅读器。
      this.notifyChange(this.baseline);

      if (failures.length > 0) {
        this.announce(`配置已保存，但部分密钥保存失败：${failures.join("；")}`, "error");
      } else {
        this.options = { ...this.options, message: undefined };
        this.announce("连接配置已保存。", "success");
      }
    } catch (error) {
      this.announce(`保存失败：${formatError(error)}`, "error");
    } finally {
      this.busy = null;
      this.render(true);
    }
  }

  private async testSelectedProfile(): Promise<void> {
    const profile = this.selectedProfile();
    if (!profile || this.busy) return;
    if (this.isDirty()) {
      this.announce("请先保存更改，再测试连接。", "warning");
      this.renderFooter();
      return;
    }
    if (!this.validateProfile(profile, true)) return;
    if (!(await this.ensureUsableCredential(profile))) return;

    this.busy = "testing";
    this.testStates.set(profile.id, { tone: "loading", label: "正在测试", message: "正在验证地址、鉴权和模型 ID…" });
    this.announce(`正在测试“${profile.name}”…`, "loading");
    this.render(true);
    try {
      const result = (await testAIProfile(profile.id)).trim();
      this.testStates.set(profile.id, {
        tone: "success",
        label: "连接可用",
        message: result || "地址、鉴权和模型 ID 已通过测试。",
      });
      this.announce(`“${profile.name}”连接成功。`, "success");
    } catch (error) {
      const message = actionableConnectionError(error);
      this.testStates.set(profile.id, { tone: "error", label: "测试失败", message });
      this.announce(`测试失败：${message}`, "error");
    } finally {
      this.busy = null;
      this.render(true);
    }
  }

  private async activateSelectedProfile(): Promise<void> {
    const profile = this.selectedProfile();
    if (!profile || this.busy || profile.id === this.draft.active_profile_id) return;
    if (this.isDirty()) {
      this.announce("请先保存更改，再设为当前连接。", "warning");
      this.renderFooter();
      return;
    }
    if (!this.validateProfile(profile, true)) return;
    if (!(await this.ensureUsableCredential(profile))) return;

    this.busy = "activating";
    this.announce(`正在切换到“${profile.name}”…`, "loading");
    this.render(true);
    try {
      const next = cloneSettings(this.baseline);
      next.active_profile_id = profile.id;
      await this.options.persistSettings(cloneSettings(next));
      this.baseline = cloneSettings(next);
      this.draft = cloneSettings(next);
      this.notifyChange(next);
      this.options = { ...this.options, message: undefined };
      this.announce(`已设为当前连接：${profile.name}。新的提问会使用它。`, "success");
    } catch (error) {
      this.announce(`切换失败：${formatError(error)}`, "error");
    } finally {
      this.busy = null;
      this.render(true);
    }
  }

  private async deleteSelectedProfile(): Promise<void> {
    const profile = this.selectedProfile();
    if (!profile || this.busy || this.draft.profiles.length <= 1) return;
    const existsInBaseline = this.baseline.profiles.some((item) => item.id === profile.id);
    if (!existsInBaseline) {
      const discard = await this.confirmAction({
        title: "放弃这个连接？",
        message: `“${profile.name || "未命名连接"}”还没有保存，填写的内容会丢失。`,
        confirmLabel: "放弃连接",
        danger: true,
      });
      if (!discard) return;
      this.draft.profiles = this.draft.profiles.filter((item) => item.id !== profile.id);
      this.keyDrafts.delete(profile.id);
      this.credentialStates.delete(profile.id);
      this.testStates.delete(profile.id);
      this.fieldErrors.delete(profile.id);
      this.selectedProfileId = resolveInitialProfileId(this.draft);
      this.announce("已放弃这个未保存的连接。", "neutral");
      this.render(false);
      return;
    }
    if (this.isDirty()) {
      this.announce("请先保存或放弃其他更改，再删除连接。", "warning");
      this.renderFooter();
      return;
    }
    const confirmed = await this.confirmAction({
      title: `删除“${profile.name || "未命名连接"}”？`,
      message: "将删除这条本地连接及其钥匙串密钥，不会删除书籍、阅读位置或问答记录。",
      confirmLabel: "删除连接",
      danger: true,
    });
    if (!confirmed) return;

    this.busy = "deleting";
    this.announce(`正在删除“${profile.name || "未命名连接"}”…`, "loading");
    this.render(true);
    let credentialRemoved = false;
    try {
      await deleteProfileApiKey(profile.id);
      credentialRemoved = true;
      this.credentialStates.set(profile.id, { phase: "ready", saved: false });

      const nextProfiles = this.draft.profiles.filter((item) => item.id !== profile.id).map(cloneProfile);
      const fallback = nextProfiles[0];
      const next: Settings = {
        profiles: nextProfiles,
        active_profile_id: this.draft.active_profile_id === profile.id ? fallback.id : this.draft.active_profile_id,
      };
      await this.options.persistSettings(cloneSettings(next));
      this.baseline = cloneSettings(next);
      this.draft = cloneSettings(next);
      this.selectedProfileId = fallback.id;
      this.keyDrafts.delete(profile.id);
      this.credentialStates.delete(profile.id);
      this.testStates.delete(profile.id);
      this.fieldErrors.delete(profile.id);
      this.notifyChange(next);
      this.announce(`已删除“${profile.name || "未命名连接"}”。`, "success");
    } catch (error) {
      const prefix = credentialRemoved ? "密钥已移除，但连接配置删除失败" : "删除失败";
      this.announce(`${prefix}：${formatError(error)}`, "error");
    } finally {
      this.busy = null;
      this.render(true);
    }
  }

  private async removeSelectedCredential(): Promise<void> {
    const profile = this.selectedProfile();
    if (!profile || this.busy) return;
    const confirmed = await this.confirmAction({
      title: "移除 API Key？",
      message: `“${profile.name || "未命名连接"}”的连接配置会保留，但在重新填写 Key 前无法使用。`,
      confirmLabel: "移除 Key",
      danger: true,
    });
    if (!confirmed) return;

    this.busy = "credential";
    this.announce("正在从 macOS 钥匙串移除密钥…", "loading");
    this.render(true);
    try {
      await deleteProfileApiKey(profile.id);
      this.keyDrafts.delete(profile.id);
      this.credentialStates.set(profile.id, { phase: "ready", saved: false });
      this.testStates.delete(profile.id);
      this.notifyChange(this.baseline);
      this.announce("API Key 已从 macOS 钥匙串移除。", "success");
    } catch (error) {
      this.announce(`移除密钥失败：${formatError(error)}`, "error");
    } finally {
      this.busy = null;
      this.render(true);
    }
  }

  private async ensureUsableCredential(profile: AIProfile): Promise<boolean> {
    if (!profile.api_key_required) return true;
    let state = this.credentialState(profile.id);
    if (state.phase !== "ready") {
      try {
        const status = await credentialStatus(profile.id);
        state = { phase: "ready", saved: status.saved };
        this.credentialStates.set(profile.id, state);
      } catch (error) {
        this.credentialStates.set(profile.id, {
          phase: "error",
          saved: false,
          message: `无法读取钥匙串：${formatError(error)}`,
        });
        this.announce(`无法读取钥匙串：${formatError(error)}`, "error");
        this.render(true);
        return false;
      }
    }
    if (!state.saved) {
      this.announce("这个连接还没有保存 API Key。填写 Key 并保存后再继续。", "warning");
      this.render(true);
      window.requestAnimationFrame(() => this.detail.querySelector<HTMLElement>("#settings-api-key")?.focus());
      return false;
    }
    return true;
  }

  private validateAllProfiles(): boolean {
    this.fieldErrors.clear();
    let firstInvalidId: string | null = null;
    for (const profile of this.draft.profiles) {
      if (!this.collectValidationErrors(profile) && firstInvalidId === null) firstInvalidId = profile.id;
    }
    if (firstInvalidId) {
      this.selectedProfileId = firstInvalidId;
      this.announce("请先补全标出的必填项。", "error");
      this.render(false);
      window.requestAnimationFrame(() => this.detail.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      return false;
    }
    return true;
  }

  private validateProfile(profile: AIProfile, focusInvalid: boolean): boolean {
    this.fieldErrors.delete(profile.id);
    const valid = this.collectValidationErrors(profile);
    if (!valid) {
      this.selectedProfileId = profile.id;
      this.announce("请先修正标出的连接信息。", "error");
      this.render(false);
      if (focusInvalid) {
        window.requestAnimationFrame(() => this.detail.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus());
      }
    }
    return valid;
  }

  private collectValidationErrors(profile: AIProfile): boolean {
    const errors: Partial<Record<FieldName, string>> = {};
    if (!profile.name.trim()) errors.name = "请输入一个便于识别的配置名称。";
    if (!profile.model_id.trim()) errors.model_id = "请输入支持图片输入的模型 ID。";

    const baseURL = profile.base_url.trim();
    if (!baseURL) {
      errors.base_url = "请输入 API 地址。";
    } else {
      try {
        const parsed = new URL(baseURL);
        if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
          errors.base_url = "API 地址必须以 http:// 或 https:// 开头。";
        } else if (parsed.username || parsed.password) {
          errors.base_url = "不要把账号或密钥写进 API 地址。";
        }
      } catch {
        errors.base_url = "请输入有效的 API 地址。";
      }
    }

    if (Object.keys(errors).length > 0) {
      this.fieldErrors.set(profile.id, errors);
      return false;
    }
    return true;
  }

  private clearFieldError(
    profileId: string,
    field: FieldName,
    control: HTMLInputElement,
    defaultHelp = "",
  ): void {
    const errors = this.fieldErrors.get(profileId);
    if (!errors?.[field]) return;
    delete errors[field];
    if (Object.keys(errors).length === 0) this.fieldErrors.delete(profileId);
    control.removeAttribute("aria-invalid");
    const help = control.parentElement?.querySelector<HTMLElement>(".settings-field-help");
    help?.classList.remove("error");
    if (help && defaultHelp) help.textContent = defaultHelp;
  }

  private isDirty(): boolean {
    if (!settingsEqual(this.baseline, this.draft)) return true;
    for (const key of this.keyDrafts.values()) {
      if (key.trim()) return true;
    }
    return false;
  }

  private announce(message: string, tone: StatusTone): void {
    this.liveMessage = message;
    this.liveTone = tone;
  }

  private notifyChange(settings: Settings): void {
    try {
      this.options.onChange?.(cloneSettings(settings));
    } catch {
      // 设置已经持久化；调用方刷新失败不应把成功状态改成保存失败。
    }
  }

  private async requestClose(): Promise<void> {
    if (this.busy) {
      this.announce("当前操作完成后才能关闭设置。", "warning");
      this.renderFooter();
      return;
    }
    if (this.isDirty()) {
      const discard = await this.confirmAction({
        title: "放弃未保存的更改？",
        message: "连接配置和尚未保存的 API Key 草稿都会丢失。",
        confirmLabel: "放弃并关闭",
        danger: true,
      });
      if (!discard) return;
    }
    this.destroy();
  }

  private destroy(): void {
    if (!this.mounted) return;
    this.mounted = false;
    this.keyDrafts.clear();
    this.restoreBackground();
    this.overlay.remove();
    this.onDestroyed();
    window.requestAnimationFrame(() => {
      if (this.previousFocus?.isConnected) this.previousFocus.focus({ preventScroll: true });
    });
  }

  private confirmAction(options: ConfirmOptions): Promise<boolean> {
    if (this.overlay.querySelector(".settings-confirm-layer")) return Promise.resolve(false);

    const previousFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const layer = createElement("div", "settings-confirm-layer");
    const confirmDialog = createElement("section", "settings-confirm-dialog");
    confirmDialog.setAttribute("role", "alertdialog");
    confirmDialog.setAttribute("aria-modal", "true");
    confirmDialog.setAttribute("aria-labelledby", "settings-confirm-title");
    confirmDialog.setAttribute("aria-describedby", "settings-confirm-message");

    const title = createElement("h3", "settings-confirm-title", options.title);
    title.id = "settings-confirm-title";
    const message = createElement("p", "settings-confirm-message", options.message);
    message.id = "settings-confirm-message";
    const actions = createElement("div", "settings-confirm-actions");
    const cancelButton = createButton("settings-button", "取消");
    cancelButton.textContent = "取消";
    const confirmButton = createButton(
      `settings-button ${options.danger ? "settings-button-confirm-danger" : "settings-button-primary"}`,
      options.confirmLabel,
    );
    confirmButton.textContent = options.confirmLabel;
    actions.append(cancelButton, confirmButton);
    confirmDialog.append(title, message, actions);
    layer.appendChild(confirmDialog);

    this.dialog.inert = true;
    this.overlay.appendChild(layer);

    return new Promise<boolean>((resolve) => {
      const finish = (confirmed: boolean) => {
        layer.remove();
        this.dialog.inert = false;
        resolve(confirmed);
        window.requestAnimationFrame(() => {
          if (!confirmed && previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
        });
      };

      cancelButton.addEventListener("click", () => finish(false), { once: true });
      confirmButton.addEventListener("click", () => finish(true), { once: true });
      layer.addEventListener("mousedown", (event) => {
        if (event.target === layer) finish(false);
      });
      confirmDialog.addEventListener("keydown", (event) => {
        event.stopPropagation();
        if (event.key === "Escape") {
          event.preventDefault();
          finish(false);
          return;
        }
        if (event.key !== "Tab") return;
        const first = cancelButton;
        const last = confirmButton;
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      });
      window.requestAnimationFrame(() => cancelButton.focus({ preventScroll: true }));
    });
  }

  private handleDialogKeyDown(event: KeyboardEvent): void {
    // 阻止阅读器的全局方向键、缩放等快捷键在设置打开时响应。
    event.stopPropagation();
    if (event.key === "Escape") {
      event.preventDefault();
      void this.requestClose();
      return;
    }
    if (event.key !== "Tab") return;

    const focusable = this.focusableElements();
    if (focusable.length === 0) {
      event.preventDefault();
      this.dialog.focus();
      return;
    }
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const current = document.activeElement;
    if (current === this.dialog || !(current instanceof Node) || !this.dialog.contains(current)) {
      event.preventDefault();
      (event.shiftKey ? last : first).focus();
    } else if (event.shiftKey && current === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && current === last) {
      event.preventDefault();
      first.focus();
    }
  }

  private focusableElements(): HTMLElement[] {
    return [...this.dialog.querySelectorAll<HTMLElement>(
      'button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    )].filter((element) => !element.hidden && element.getClientRects().length > 0);
  }

  private focusInitialControl(): void {
    const selected = this.sidebar.querySelector<HTMLButtonElement>("#settings-selected-profile");
    if (selected) {
      selected.focus({ preventScroll: true });
    } else {
      this.dialog.focus({ preventScroll: true });
    }
  }

  private captureFocus(): FocusSnapshot | null {
    const active = document.activeElement;
    if (!(active instanceof HTMLElement) || !this.dialog.contains(active) || !active.id) return null;
    if (active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement) {
      return { id: active.id, selectionStart: active.selectionStart, selectionEnd: active.selectionEnd };
    }
    return { id: active.id, selectionStart: null, selectionEnd: null };
  }

  private restoreFocus(snapshot: FocusSnapshot): void {
    window.requestAnimationFrame(() => {
      if (!this.mounted) return;
      const element = this.dialog.querySelector<HTMLElement>(`#${snapshot.id}`);
      if (!element) return;
      element.focus({ preventScroll: true });
      if (
        snapshot.selectionStart !== null &&
        snapshot.selectionEnd !== null &&
        (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement)
      ) {
        try {
          element.setSelectionRange(snapshot.selectionStart, snapshot.selectionEnd);
        } catch {
          // 某些 input 类型不支持选择范围；焦点恢复本身仍然有效。
        }
      }
    });
  }

  private makeBackgroundInert(): void {
    const app = document.getElementById("app");
    if (!app) return;
    this.appWasInert = app.inert;
    this.appAriaHidden = app.getAttribute("aria-hidden");
    app.inert = true;
    app.setAttribute("aria-hidden", "true");
  }

  private restoreBackground(): void {
    const app = document.getElementById("app");
    if (!app) return;
    app.inert = this.appWasInert;
    if (this.appAriaHidden === null) app.removeAttribute("aria-hidden");
    else app.setAttribute("aria-hidden", this.appAriaHidden);
  }
}

function createElement<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className = "",
  text = "",
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text) element.textContent = text;
  return element;
}

function createButton(className: string, ariaLabel: string): HTMLButtonElement {
  const button = createElement("button", className);
  button.type = "button";
  button.setAttribute("aria-label", ariaLabel);
  return button;
}

function providerSpec(provider: AIProviderKind): ProviderSpec {
  return PROVIDERS[provider] ?? PROVIDERS.open_ai_compatible;
}

function cloneProfile(profile: AIProfile): AIProfile {
  return {
    id: profile.id,
    name: profile.name,
    provider: profile.provider,
    base_url: profile.base_url,
    model_id: profile.model_id,
    api_key_required: profile.api_key_required,
  };
}

function cloneSettings(settings: Settings): Settings {
  return {
    active_profile_id: settings.active_profile_id,
    profiles: settings.profiles.map(cloneProfile),
  };
}

function normalizeSettings(settings: Settings): Settings {
  const profiles = settings.profiles.map(cloneProfile);
  if (profiles.length === 0) {
    profiles.push({
      id: "model-studio-default",
      name: "阿里云百炼",
      provider: "model_studio",
      base_url: MODEL_STUDIO_URL,
      model_id: "qwen3-vl-plus",
      api_key_required: true,
    });
  }
  const active = profiles.some((profile) => profile.id === settings.active_profile_id)
    ? settings.active_profile_id
    : profiles[0].id;
  return { active_profile_id: active, profiles };
}

function normalizedDraft(settings: Settings): Settings {
  const next = cloneSettings(settings);
  next.profiles = next.profiles.map((profile) => {
    const spec = providerSpec(profile.provider);
    return {
      ...profile,
      name: profile.name.trim(),
      base_url: (spec.customURL ? profile.base_url : spec.baseURL).trim().replace(/\/+$/, ""),
      model_id: profile.model_id.trim(),
      api_key_required: spec.customURL ? profile.api_key_required : true,
    };
  });
  return next;
}

function resolveInitialProfileId(settings: Settings, preferred?: string): string {
  if (preferred && settings.profiles.some((profile) => profile.id === preferred)) return preferred;
  if (settings.profiles.some((profile) => profile.id === settings.active_profile_id)) return settings.active_profile_id;
  return settings.profiles[0]?.id ?? "";
}

function settingsEqual(left: Settings, right: Settings): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function hasCompleteMetadata(profile: AIProfile): boolean {
  if (!profile.name.trim() || !profile.model_id.trim() || !profile.base_url.trim()) return false;
  try {
    const url = new URL(profile.base_url.trim());
    return (url.protocol === "http:" || url.protocol === "https:") && !url.username && !url.password;
  } catch {
    return false;
  }
}

function nextProfileName(profiles: AIProfile[]): string {
  const names = new Set(profiles.map((profile) => profile.name));
  let index = profiles.length + 1;
  let candidate = `新的 AI 连接 ${index}`;
  while (names.has(candidate)) {
    index += 1;
    candidate = `新的 AI 连接 ${index}`;
  }
  return candidate;
}

function credentialLabel(profile: AIProfile, state: CredentialState): string {
  if (!profile.api_key_required) return "无需 Key";
  if (state.phase === "loading") return "检查中";
  if (state.phase === "error") return "读取失败";
  return state.saved ? "已保存 · 使用时验证" : "尚未保存";
}

function keyPlaceholder(profile: AIProfile, state: CredentialState): string {
  if (!profile.api_key_required) return "此连接不使用 API Key";
  if (state.phase === "loading") return "正在检查钥匙串…";
  if (state.saved) return "已保存 · 首次使用时由 macOS 验证授权 · 输入新 Key 可替换";
  return "粘贴 API Key";
}

function modelExplanationText(profile: AIProfile): string {
  const match = MODEL_SUGGESTIONS[profile.provider].find((suggestion) => suggestion.id === profile.model_id.trim());
  if (match) return `${match.label} · ${match.explanation}`;
  if (profile.provider === "open_ai_compatible") return "填写服务端提供且支持图片输入的模型 ID。";
  return "可以选择建议模型，也可以填写其他支持图片输入的模型 ID。";
}

function formatError(error: unknown): string {
  if (error instanceof Error && error.message.trim()) return error.message.trim();
  if (typeof error === "string" && error.trim()) return error.trim();
  try {
    const serialized = JSON.stringify(error);
    return serialized && serialized !== "{}" ? serialized : "未知错误";
  } catch {
    return "未知错误";
  }
}

function actionableConnectionError(error: unknown): string {
  const message = formatError(error);
  const lower = message.toLowerCase();
  if (lower.includes("401") || lower.includes("unauthorized") || lower.includes("api key")) {
    return "鉴权失败。请检查 API Key 是否正确，并确认它属于当前服务。";
  }
  if (lower.includes("404") || lower.includes("model") && lower.includes("not")) {
    return "找不到 API 地址或模型。请核对服务地址和模型 ID。";
  }
  if (lower.includes("timeout") || lower.includes("timed out") || message.includes("超时")) {
    return "连接超时。请检查网络、服务地址，或稍后重试。";
  }
  return message;
}
