const state = {
  stepIndex: 0,
  steps: ["patient", "photo", "questions", "result"],
  cases: [],
  selectedCaseId: null,
  modelReady: false,
  analyzing: false,
};

const labels = {
  loading: "Loading Gemma 4",
  ready: "Gemma 4 ready",
  error: "Gemma 4 unavailable",
  analyzing: "Analyzing...",
  analyze: "Analyze with Gemma 4",
  resultTitle: "Result",
  low: "Low suspicion",
  moderate: "Moderate suspicion",
  high: "High suspicion",
  insufficient_image: "Insufficient image",
  visualRisk: "Dermatologic visual risk",
  clinicalRisk: "Clinical-neural risk",
  imageQuality: "Image quality",
  findingsByRegion: "Findings by region",
  symptoms: "Relevant symptoms",
  riskFactors: "Factors that raised the risk",
  confidence: "Confidence limitations",
  reassuring: "Factors that lower suspicion",
  reasoning: "Clinical reasoning",
  referral: "Referral reason",
  nextAction: "Next action for the health worker",
  safety:
    "Neurological signs, wounds, loss of strength, or rapid worsening require in-person evaluation. This result does not replace a medical exam.",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.prototype.slice.call(document.querySelectorAll(selector));

async function init() {
  bindEvents();
  await loadCases();
  await pollStatus();
  setInterval(pollStatus, 4500);
  renderStep();
}

function bindEvents() {
  $$(".step").forEach((button) => {
    button.addEventListener("click", () => {
      state.stepIndex = state.steps.indexOf(button.dataset.step);
      renderStep();
    });
  });

  $("#backButton").addEventListener("click", () => {
    state.stepIndex = Math.max(0, state.stepIndex - 1);
    renderStep();
  });

  $("#nextButton").addEventListener("click", () => {
    state.stepIndex = Math.min(state.steps.length - 1, state.stepIndex + 1);
    renderStep();
  });

  $("#analyzeButton").addEventListener("click", analyze);
}

async function loadCases() {
  const response = await fetch("/api/cases");
  const data = await response.json();
  state.cases = data.cases || [];
  state.selectedCaseId = state.cases.length ? state.cases[0].id : null;
  $("#caseCount").textContent = String(state.cases.length);
  renderCases();
}

async function pollStatus() {
  try {
    const response = await fetch("/api/status");
    const status = await response.json();
    state.modelReady = status.status === "ready";
    $("#modelName").textContent = status.model_repo || "-";
    $("#modelFile").textContent = status.model_file || "-";
    $("#sideStatus").textContent = status.detail || status.status;
    renderStatus(status);
  } catch (error) {
    state.modelReady = false;
    renderStatus({ status: "error", detail: String(error) });
  }
  renderControls();
}

function renderStatus(status) {
  const statusBox = $("#modelStatus");
  statusBox.className = `model-status model-status-${status.status}`;

  const text =
    status.status === "ready"
      ? labels.ready
      : status.status === "error" || status.status === "stopped"
        ? labels.error
        : labels.loading;
  statusBox.innerHTML = `<span class="status-dot"></span><span>${escapeHtml(text)}</span>`;
}

function renderCases() {
  const grid = $("#caseGrid");
  grid.innerHTML = state.cases
    .map(
      (item) => `
        <button class="case-card ${item.id === state.selectedCaseId ? "selected" : ""}" type="button" data-case="${escapeHtml(item.id)}">
          <img src="${escapeHtml(item.image_url)}" alt="${escapeHtml(item.title)}" loading="lazy" />
          <span>${escapeHtml(item.title)}</span>
        </button>
      `,
    )
    .join("");

  $$(".case-card").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedCaseId = button.dataset.case;
      renderCases();
    });
  });
}

function renderStep() {
  const activeStep = state.steps[state.stepIndex];
  $$(".step").forEach((button) => button.classList.toggle("active", button.dataset.step === activeStep));
  $$(".screen").forEach((screen) => screen.classList.toggle("active", screen.dataset.screen === activeStep));
  renderControls();
}

function renderControls() {
  $("#backButton").disabled = state.stepIndex === 0 || state.analyzing;
  $("#nextButton").disabled = state.stepIndex === state.steps.length - 1 || state.analyzing;
  $("#analyzeButton").disabled = !state.modelReady || state.analyzing || !state.selectedCaseId;
  $("#analyzeButton").textContent = state.analyzing ? labels.analyzing : labels.analyze;
}

async function analyze() {
  state.analyzing = true;
  state.stepIndex = 3;
  renderStep();
  renderLoadingResult();

  const payload = {
    case_id: state.selectedCaseId,
    language: "en",
    patient_name: $("#patientName").value,
    patient_age: Number($("#patientAge").value || 0),
    patient_sex: $("#patientSex").value,
    has_numbness: $("#hasNumbness").checked,
    changed_color: $("#changedColor").checked,
    has_contact_with_confirmed_case: $("#hasContact").checked,
    has_nerve_pain_or_shock: $("#hasNervePain").checked,
    has_muscle_weakness: $("#hasWeakness").checked,
    has_dryness_or_hair_loss: $("#hasDryness").checked,
    has_multiple_lesions: $("#hasMultiple").checked,
    has_wound_or_burn_without_pain: $("#hasWound").checked,
    duration: $("#duration").value,
    notes: $("#notes").value,
  };

  try {
    const response = await fetch("/api/analyze", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });

    if (!response.ok) {
      const body = await response.json().catch(() => ({}));
      throw new Error(body.detail || `HTTP ${response.status}`);
    }

    const result = await response.json();
    renderResult(result);
  } catch (error) {
    renderError(error);
  } finally {
    state.analyzing = false;
    renderControls();
  }
}

function renderLoadingResult() {
  $("#resultPanel").className = "result-panel empty";
  $("#resultPanel").innerHTML = `
    <h2>${escapeHtml(labels.resultTitle)}</h2>
    <p>${escapeHtml(labels.analyzing)}</p>
  `;
}

function renderError(error) {
  $("#resultPanel").className = "result-panel";
  $("#resultPanel").innerHTML = `
    <div class="risk-header">
      <span class="risk-badge risk-high">${escapeHtml(labels.error)}</span>
    </div>
    <div class="warning-note">${escapeHtml(String(error.message || error))}</div>
  `;
}

function renderResult(result) {
  const level = result.risk_level || "low";
  const levelLabel = labels[level] || level;

  $("#resultPanel").className = "result-panel";
  $("#resultPanel").innerHTML = `
    <div class="risk-header">
      <span class="risk-badge risk-${escapeHtml(level)}">${escapeHtml(levelLabel)}</span>
      <span class="score">${Number(result.score || 0)}/100</span>
    </div>
    ${result.consistency_note ? `<div class="warning-note">${escapeHtml(result.consistency_note)}</div>` : ""}
    <div class="score-grid">
      <div class="score-card">
        <strong>${escapeHtml(labels.visualRisk)}</strong>
        <span>${escapeHtml(labels[result.visual_risk_level] || result.visual_risk_level)} · ${Number(result.visual_risk_score || 0)}/100</span>
      </div>
      <div class="score-card">
        <strong>${escapeHtml(labels.clinicalRisk)}</strong>
        <span>${escapeHtml(labels[result.clinical_neural_risk_level] || result.clinical_neural_risk_level)} · ${Number(result.clinical_neural_risk_score || 0)}/100</span>
      </div>
    </div>
    ${renderList(labels.imageQuality, result.image_quality_summary)}
    ${renderRegions(labels.findingsByRegion, result.region_findings)}
    ${renderList(labels.symptoms, result.relevant_symptoms)}
    ${renderList(labels.riskFactors, result.risk_increasing_factors)}
    ${renderList(labels.confidence, result.confidence_limiting_factors)}
    ${renderList(labels.reassuring, result.reassuring_factors)}
    ${renderList(labels.reasoning, result.reasoning)}
    ${renderParagraph(labels.referral, result.referral_reason)}
    ${renderParagraph(labels.nextAction, result.next_action)}
    <div class="warning-note">${escapeHtml(labels.safety)}</div>
  `;
}

function renderList(title, items) {
  if (!items || !items.length) return "";
  return `
    <section class="result-section">
      <h3>${escapeHtml(title)}</h3>
      <ul>${items.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>
    </section>
  `;
}

function renderRegions(title, regions) {
  if (!regions || !regions.length) return "";
  return `
    <section class="result-section">
      <h3>${escapeHtml(title)}</h3>
      ${regions
        .map(
          (region) => `
            <div class="region-card">
              <strong>${escapeHtml(region.region || "")}</strong>
              ${region.findings && region.findings.length ? `<ul>${region.findings.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul>` : ""}
            </div>
          `,
        )
        .join("")}
    </section>
  `;
}

function renderParagraph(title, text) {
  if (!text) return "";
  return `
    <section class="result-section">
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(text)}</p>
    </section>
  `;
}

function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

init();
