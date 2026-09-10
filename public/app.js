const remaining = document.querySelector('#remaining');
const needle = document.querySelector('#needle');
const status = document.querySelector('#status');
const reset = document.querySelector('#reset');
const weekly = document.querySelector('#weekly');
const plan = document.querySelector('#plan');
const refresh = document.querySelector('#refresh');

function formatDate(value) {
  if (!value) return 'Non communiqué';
  const date = new Date(typeof value === 'number' ? value * 1000 : value);
  return Number.isNaN(date.valueOf()) ? 'Non communiqué' : date.toLocaleString('fr-FR', { dateStyle: 'medium', timeStyle: 'short' });
}

function setGauge(value) {
  const percent = Math.round(value);
  remaining.textContent = `${percent}%`;
  needle.style.setProperty('--rotation', `${-90 + percent * 1.8}deg`);
  document.documentElement.style.setProperty('--gauge-color', percent <= 10 ? '#ef4444' : percent <= 25 ? '#f59e0b' : '#35c98a');
}

async function loadUsage() {
  refresh.disabled = true;
  status.textContent = 'Mise à jour…';
  try {
    const response = await fetch('/api/usage');
    const data = await response.json();
    if (!response.ok) throw new Error(data.error ?? 'La demande a échoué.');
    setGauge(data.remainingPercent);
    reset.textContent = formatDate(data.resetAt);
    weekly.textContent = `${Math.round(data.weeklyRemainingPercent)}% restant${data.weeklyResetAt ? `, jusqu’au ${formatDate(data.weeklyResetAt)}` : ''}`;
    plan.textContent = data.plan ?? 'Non communiqué';
    status.textContent = data.limitReached ? 'La limite est atteinte.' : 'Données à jour.';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    refresh.disabled = false;
  }
}

refresh.addEventListener('click', loadUsage);
loadUsage();
