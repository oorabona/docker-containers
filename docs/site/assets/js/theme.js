// Shared theme management for dashboard pages
// Included before page-specific scripts
// Globals: currentTheme, initTheme, applyTheme, toggleTheme
// Note: uses global scope intentionally — this Jekyll site has no third-party scripts
var currentTheme = localStorage.getItem('preferredTheme') || 'dark';

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  var icon = document.querySelector('.theme-toggle i');
  if (icon) icon.className = theme === 'dark' ? 'ti ti-moon' : 'ti ti-sun';
}

function initTheme() {
  var saved = localStorage.getItem('preferredTheme');
  if (!saved) {
    currentTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  applyTheme(currentTheme);
}

function toggleTheme() {
  currentTheme = currentTheme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('preferredTheme', currentTheme);
  applyTheme(currentTheme);
}

// Apply theme immediately to avoid flash
initTheme();
