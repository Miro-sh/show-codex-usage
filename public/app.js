const remaining = document.querySelector('#remaining');
const gaugeFill = document.querySelector('#gauge-fill');
const reset = document.querySelector('#reset');
const weekly = document.querySelector('#weekly');
const primaryLabel = document.querySelector('#primary-label');
const secondaryLabel = document.querySelector('#secondary-label');
const secondaryRow = document.querySelector('#secondary-row');
const lastResetDate = document.querySelector('#last-reset-date');
const lastResetAgo = document.querySelector('#last-reset-ago');
let lastResetAt = null;

function formatDate(value) {
  if (!value) return 'Non communiqué';
  const date = new Date(typeof value === 'number' ? value * 1000 : value);
  return Number.isNaN(date.valueOf()) ? 'Non communiqué' : date.toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
}

function setGauge(value) {
  const percent = Math.round(value);
  remaining.textContent = `${percent}%`;
  // 0 % is red and 100 % is green, with every intermediate value moving through the hue range.
  gaugeFill.style.stroke = `hsl(${percent * 1.2} 72% 52%)`;
  gaugeFill.style.strokeDasharray = `${percent} 100`;
}

function formatWindowLabel(seconds, fallback) {
  if (!seconds) return fallback;
  if (seconds === 604800) return 'Limite hebdomadaire';
  if (seconds % 86400 === 0) return `Limite sur ${seconds / 86400} j`;
  if (seconds % 3600 === 0) return `Limite sur ${seconds / 3600} h`;
  return fallback;
}

function formatRelativeDate(value) {
  const elapsedSeconds = (Date.now() - value.getTime()) / 1000;
  const units = [
    ['year', 31536000],
    ['month', 2592000],
    ['day', 86400],
    ['hour', 3600],
    ['minute', 60],
    ['second', 1]
  ];
  const [unit, seconds] = units.find(([, size]) => elapsedSeconds >= size) ?? units.at(-1);
  return new Intl.RelativeTimeFormat('fr-FR', { numeric: 'auto' }).format(-Math.floor(elapsedSeconds / seconds), unit);
}

function renderLastReset() {
  if (!lastResetAt) return;
  lastResetDate.textContent = lastResetAt.toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
  lastResetAgo.textContent = formatRelativeDate(lastResetAt);
}

async function loadUsage() {
  try {
    const response = await fetch('/api/usage');
    const data = await response.json();
    if (!response.ok) throw new Error(data.error ?? 'La demande a échoué.');
    setGauge(data.remainingPercent);
    primaryLabel.textContent = formatWindowLabel(data.primaryWindowSeconds, 'Limite principale');
    reset.textContent = formatDate(data.resetAt);
    if (data.weeklyRemainingPercent == null) {
      secondaryRow.hidden = true;
    } else {
      secondaryRow.hidden = false;
      secondaryLabel.textContent = formatWindowLabel(data.secondaryWindowSeconds, 'Limite secondaire');
      weekly.textContent = `${Math.round(data.weeklyRemainingPercent)}%${data.weeklyResetAt ? `, jusqu’au ${formatDate(data.weeklyResetAt)}` : ''}`;
    }
  } catch (error) {
    console.error(error);
  }
}

async function loadResetRequests() {
  try {
    const response = await fetch('/api/reset-requests');
    const data = await response.json();
    if (!response.ok) throw new Error(data.error ?? 'La demande a échoué.');
    lastResetAt = new Date(data.lastResetAt);
    renderLastReset();
  } catch (error) {
    console.error(error);
  }
}

loadUsage();
loadResetRequests();
setInterval(renderLastReset, 60_000);
