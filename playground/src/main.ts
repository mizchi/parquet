import '../generated/playground_bridge.js';
import './style.css';

import { toBridgeInput } from './lib/input.ts';
import type { PlaygroundResult, PlaygroundTable } from './bridge.d.ts';

const defaultSchema = JSON.stringify(
  [
    { name: 'id', type: 'Int32', repetition: 'Required' },
    { name: 'score', type: 'Int64', repetition: 'Optional' },
    { name: 'name', type: 'String', repetition: 'Optional' },
  ],
  null,
  2,
);

const defaultRows = JSON.stringify(
  [
    { id: 1, score: 10, name: 'alice' },
    { id: 2, score: null, name: 'bob' },
    { id: 3, score: 30, name: null },
  ],
  null,
  2,
);

const defaultSql = `select * from read_parquet('playground.parquet') order by id`;
const aggregateSql = `select count(*) as rows, avg(score) as avg_score from read_parquet('playground.parquet')`;

const app = document.querySelector<HTMLDivElement>('#app');

if (!app) {
  throw new Error('app root not found');
}

app.innerHTML = `
  <main class="shell">
    <section class="hero panel rise">
      <div>
        <p class="eyebrow">MoonBit + DuckDB WASM</p>
        <h1>Parquet Browser Playground</h1>
        <p class="lede">
          ` + 'Edit schema / rows / SQL to generate parquet with MoonBit and query it immediately in DuckDB WASM.' + `
        </p>
      </div>
      <div class="hero-actions">
        <button id="preset-scan" class="ghost-button" type="button">Scan Query</button>
        <button id="preset-agg" class="ghost-button" type="button">Aggregate Query</button>
      </div>
    </section>

    <section class="workspace">
      <form id="playground-form" class="panel form-panel rise">
        <div class="form-header">
          <div>
            <p class="eyebrow">Inputs</p>
            <h2>Editable Payload</h2>
          </div>
          <button id="run-button" class="action-button" type="submit">Run Playground</button>
        </div>

        <label class="field">
          <span>Schema JSON</span>
          <textarea id="schema-input" spellcheck="false"></textarea>
        </label>

        <label class="field">
          <span>Rows JSON</span>
          <textarea id="rows-input" spellcheck="false"></textarea>
        </label>

        <label class="field">
          <span>DuckDB SQL</span>
          <textarea id="sql-input" spellcheck="false"></textarea>
        </label>

        <div class="note">
          <strong>Supported parquet writer types:</strong> Int32, Int64, String.
        </div>
      </form>

      <section class="results">
        <div class="panel status-panel rise">
          <div class="status-header">
            <div>
              <p class="eyebrow">Status</p>
              <h2>Execution</h2>
            </div>
            <a id="download-link" class="download-link" download>Download parquet</a>
          </div>
          <p id="status-message" class="status-message">Ready.</p>
          <p id="error-message" class="error-message" hidden></p>
          <div id="summary-grid" class="summary-grid"></div>
        </div>

        <div class="panel result-panel rise">
          <div class="result-header">
            <p class="eyebrow">Roundtrip</p>
            <h2>Parquet Preview</h2>
          </div>
          <div id="preview-table" class="table-shell empty-state">No parquet preview yet.</div>
        </div>

        <div class="panel result-panel rise">
          <div class="result-header">
            <p class="eyebrow">DuckDB</p>
            <h2>Query Result</h2>
          </div>
          <div id="query-table" class="table-shell empty-state">No query result yet.</div>
        </div>
      </section>
    </section>
  </main>
`;

const form = app.querySelector<HTMLFormElement>('#playground-form');
const schemaInput = app.querySelector<HTMLTextAreaElement>('#schema-input');
const rowsInput = app.querySelector<HTMLTextAreaElement>('#rows-input');
const sqlInput = app.querySelector<HTMLTextAreaElement>('#sql-input');
const runButton = app.querySelector<HTMLButtonElement>('#run-button');
const presetScanButton = app.querySelector<HTMLButtonElement>('#preset-scan');
const presetAggButton = app.querySelector<HTMLButtonElement>('#preset-agg');
const statusMessage = app.querySelector<HTMLParagraphElement>('#status-message');
const errorMessage = app.querySelector<HTMLParagraphElement>('#error-message');
const summaryGrid = app.querySelector<HTMLDivElement>('#summary-grid');
const previewTable = app.querySelector<HTMLDivElement>('#preview-table');
const queryTable = app.querySelector<HTMLDivElement>('#query-table');
const downloadLink = app.querySelector<HTMLAnchorElement>('#download-link');

if (
  !form ||
  !schemaInput ||
  !rowsInput ||
  !sqlInput ||
  !runButton ||
  !presetScanButton ||
  !presetAggButton ||
  !statusMessage ||
  !errorMessage ||
  !summaryGrid ||
  !previewTable ||
  !queryTable ||
  !downloadLink
) {
  throw new Error('playground UI did not mount correctly');
}

schemaInput.value = defaultSchema;
rowsInput.value = defaultRows;
sqlInput.value = defaultSql;

let currentDownloadUrl: string | null = null;

const escapeHtml = (value: string): string =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

const formatBytes = (size: number): string => {
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
};

const renderTable = (table: PlaygroundTable): string => {
  if (table.columns.length === 0) {
    return '<div class="empty-state">No columns returned.</div>';
  }

  const head = table.columns
    .map((column) => `<th>${escapeHtml(column)}</th>`)
    .join('');

  const body = table.rows
    .map((row, rowIndex) => {
      const cells = row
        .map((value, columnIndex) => {
          const isNull = table.nulls[rowIndex]?.[columnIndex] ?? false;
          const rendered = isNull ? '<span class="null-chip">NULL</span>' : escapeHtml(value);
          return `<td>${rendered}</td>`;
        })
        .join('');
      return `<tr>${cells}</tr>`;
    })
    .join('');

  return `
    <table class="result-table">
      <thead><tr>${head}</tr></thead>
      <tbody>${body}</tbody>
    </table>
  `;
};

const toParquetBlob = (result: PlaygroundResult): Blob =>
  new Blob([result.parquetBytes], { type: 'application/octet-stream' });

const setDownload = (result: PlaygroundResult): void => {
  if (currentDownloadUrl) {
    URL.revokeObjectURL(currentDownloadUrl);
  }
  currentDownloadUrl = URL.createObjectURL(toParquetBlob(result));
  downloadLink.href = currentDownloadUrl;
  downloadLink.download = result.parquetFileName;
  downloadLink.textContent = `Download ${result.parquetFileName}`;
  downloadLink.hidden = false;
};

const setSummary = (result: PlaygroundResult): void => {
  const parquetSize = toParquetBlob(result).size;
  const cards = [
    { label: 'Parquet Size', value: formatBytes(parquetSize) },
    { label: 'Preview Rows', value: String(result.preview.rows.length) },
    { label: 'Query Rows', value: String(result.query.rows.length) },
    { label: 'Columns', value: String(result.query.columns.length) },
  ];
  summaryGrid.innerHTML = cards
    .map(
      (card) => `
        <article class="summary-card">
          <span>${card.label}</span>
          <strong>${card.value}</strong>
        </article>
      `,
    )
    .join('');
};

const setBusy = (busy: boolean): void => {
  runButton.disabled = busy;
  runButton.textContent = busy ? 'Running…' : 'Run Playground';
};

const setError = (message: string | null): void => {
  if (!message) {
    errorMessage.hidden = true;
    errorMessage.textContent = '';
    return;
  }
  errorMessage.hidden = false;
  errorMessage.textContent = message;
};

const runPlayground = async (): Promise<void> => {
  if (!window.parquetDuckdbPlayground) {
    throw new Error('MoonBit bridge did not initialize');
  }

  setBusy(true);
  setError(null);
  statusMessage.textContent = 'Building parquet payload and starting DuckDB WASM…';

  try {
    const input = toBridgeInput(schemaInput.value, rowsInput.value, sqlInput.value);
    const result = await window.parquetDuckdbPlayground.runPlayground(input);
    statusMessage.textContent = 'Execution finished.';
    setSummary(result);
    setDownload(result);
    previewTable.classList.remove('empty-state');
    queryTable.classList.remove('empty-state');
    previewTable.innerHTML = renderTable(result.preview);
    queryTable.innerHTML = renderTable(result.query);
  } catch (error) {
    setError(error instanceof Error ? error.message : String(error));
    statusMessage.textContent = 'Execution failed.';
  } finally {
    setBusy(false);
  }
};

form.addEventListener('submit', (event) => {
  event.preventDefault();
  void runPlayground();
});

presetScanButton.addEventListener('click', () => {
  sqlInput.value = defaultSql;
});

presetAggButton.addEventListener('click', () => {
  sqlInput.value = aggregateSql;
});

void runPlayground();
